#!/usr/bin/env bash
# install_cts.sh — Project-local claude-trading-skills installation (per-entry symlinks).
#
# Each managed entry is symlinked into the target project's `.claude/` tree so
# Claude Code's discovery (which only scans one level deep) finds it:
#
#   skills/<name>/        → <project>/.claude/skills/<name>      (dir symlink)
#   commands/<name>.md    → <project>/.claude/commands/<name>.md (file symlink)
#   agents/<name>.md      → <project>/.claude/agents/<name>.md   (file symlink)
#
# A versioned manifest at `<project>/.cts/installed-skills.txt` records every
# entry this installer created. Uninstall and reconcile read from that manifest
# and never touch user-owned files/symlinks that happen to share a name.
#
# Usage:
#   bash tools/install_cts.sh [project_path] [options]
#
# Actions (mutually exclusive, default: auto):
#   default           install if no manifest, else reconcile
#   --reconcile       explicit reconcile; refuse if no manifest
#   --uninstall       remove only entries in manifest; preserve manifest as .prev
#
# Options:
#   --cts-repo PATH        override cts-repo discovery
#   --dry-run              show plan, no writes
#   --quiet                no prompts; abort on any condition that would prompt
#   --no-doc               skip CLAUDE.md update
#   --skills-only          manage only skills/ (skip commands/ and agents/)
#   --adopt-existing KEY   adopt a non-managed symlink that already points to
#                          the correct upstream target. KEY is "kind:name"
#                          (e.g. "skill:vcp-screener"). Repeatable.
#   --replace-link KEY     replace a managed symlink that points to a DIFFERENT
#                          entry than expected. KEY is "kind:name". Repeatable.
#   --clear-stale-lock     remove stale lock dir from a crashed prior run
#                          (host+PID metadata is verified before removal)
#
# Safety rules enforced:
#   S1  Never delete a path that is not a symlink.
#   S2  Never delete a symlink whose target is outside the configured cts-repo.
#   S3  Never delete a symlink not listed in the manifest (except via --uninstall
#       which only deletes manifest entries).
#   S4  Never overwrite an existing path during CREATE — abort by default.
#   S5  Manifest write is atomic (temp + rename in same dir).
#   S6  Concurrent runs in same project serialize via mkdir lockdir.
#   S7  Crash mid-apply leaves the previous manifest intact; rerun adopts.
#   S8  Uninstall revalidates each managed symlink's target before removing.
#   S9  If .cts/, .claude/, .claude/skills/, .claude/commands/, or
#       .claude/agents/ is itself a symlink, abort.
#   S10 Reject upstream entries that are symlinks to outside cts-repo.
#   S11 Revalidate exact target match (lstat + readlink) before every mutation.
#   S12 Temp files live in the same directory as the destination.
#   S13 Names must match ^[A-Za-z0-9][A-Za-z0-9._-]*$ (slug regex).

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
MANIFEST_VERSION="1"
MANIFEST_NAME="installed-skills.txt"
MANIFEST_PREV_NAME="installed-skills.txt.prev"
CTS_DIR_NAME=".cts"
LOCK_DIR_NAME=".install.lock.d"
SKILLS_REL=".claude/skills"
COMMANDS_REL=".claude/commands"
AGENTS_REL=".claude/agents"
DOC_FILE_NAME="CLAUDE.md"
BLOCK_BEGIN="<!-- CTS:BEGIN -->"
BLOCK_END="<!-- CTS:END -->"
SAFE_NAME_REGEX='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# ─── Argument parsing ─────────────────────────────────────────────────────────
PROJECT_PATH=""
CTS_REPO_OVERRIDE=""
ACTION="auto"        # auto | reconcile | uninstall
DRY_RUN=false
QUIET=false
NO_DOC=false
SKILLS_ONLY=false
CLEAR_STALE_LOCK=false
ADOPT_KEYS=()
REPLACE_LINK_KEYS=()

usage() { sed -n '2,50p' "$0" | sed 's/^# \?//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reconcile)         ACTION="reconcile"; shift ;;
        --uninstall)         ACTION="uninstall"; shift ;;
        --cts-repo)          CTS_REPO_OVERRIDE="${2:?--cts-repo requires path}"; shift 2 ;;
        --dry-run)           DRY_RUN=true; shift ;;
        --quiet)             QUIET=true; shift ;;
        --no-doc)            NO_DOC=true; shift ;;
        --skills-only)       SKILLS_ONLY=true; shift ;;
        --clear-stale-lock)  CLEAR_STALE_LOCK=true; shift ;;
        --adopt-existing)    ADOPT_KEYS+=("${2:?--adopt-existing requires kind:name}"); shift 2 ;;
        --replace-link)      REPLACE_LINK_KEYS+=("${2:?--replace-link requires kind:name}"); shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        --*)                 echo "Unknown option: $1" >&2; exit 2 ;;
        *)
            if [[ -z "$PROJECT_PATH" ]]; then PROJECT_PATH="$1"
            else echo "Error: unexpected positional: $1" >&2; exit 2; fi
            shift ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()      { $QUIET && return 0; echo "$@"; }
warn()     { echo "warning: $*" >&2; }
die()      { echo "error: $*" >&2; exit 1; }
prompt()   { $QUIET && return 1; printf "%s " "$1" >&2; read -r REPLY; [[ "$REPLY" =~ ^[Yy]$ ]]; }
abs_path() { ( cd "$1" 2>/dev/null && pwd ) || return 1; }

is_safe_name() { [[ "$1" =~ $SAFE_NAME_REGEX ]]; }

# Read symlink target without following further (one hop)
read_link_target() {
    if command -v greadlink >/dev/null 2>&1; then greadlink "$1"
    else readlink "$1"; fi
}

# Resolve a path, following all symlinks, to a canonical absolute path
canonicalize() {
    if command -v greadlink >/dev/null 2>&1; then greadlink -f "$1" 2>/dev/null || true
    elif readlink -f "$1" 2>/dev/null; then :
    else
        # macOS fallback: cd + pwd
        local d f
        if [[ -d "$1" ]]; then ( cd "$1" && pwd )
        else d="$(dirname "$1")"; f="$(basename "$1")"; ( cd "$d" 2>/dev/null && echo "$(pwd)/$f" )
        fi
    fi
}

# True if $1 is a symlink (lstat-style; doesn't follow)
is_symlink() { [[ -L "$1" ]]; }

# Find cts-repo location: prefer --cts-repo, then script's parent, then $CTS_REPO env, then guesses
resolve_cts_repo() {
    local p
    if [[ -n "$CTS_REPO_OVERRIDE" ]]; then
        p="$(abs_path "$CTS_REPO_OVERRIDE")" || die "--cts-repo path not found: $CTS_REPO_OVERRIDE"
        [[ -d "$p/skills" ]] || die "--cts-repo has no skills/ subdir: $p"
        echo "$p"; return
    fi
    local script_dir parent
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    parent="$(cd "$script_dir/.." && pwd)"
    if [[ -d "$parent/skills" ]]; then echo "$parent"; return; fi
    if [[ -n "${CTS_REPO:-}" && -d "$CTS_REPO/skills" ]]; then abs_path "$CTS_REPO"; return; fi
    for guess in \
        "$HOME/codes/claude-trading-skills" \
        "$HOME/Desktop/claude-trading-skills" \
        "$HOME/claude-trading-skills" ; do
        [[ -d "$guess/skills" ]] && { abs_path "$guess"; return; }
    done
    die "cannot find claude-trading-skills repo. Use --cts-repo PATH or set CTS_REPO env var."
}

# ─── Upstream inventory ───────────────────────────────────────────────────────
# Output one line per managed entry: "kind|name"
#   skill   = subdir of skills/ containing SKILL.md
#   command = .md file in commands/
#   agent   = .md file in agents/
build_upstream_inventory() {
    local repo="$1"
    local entries=() name src resolved

    # skills/
    if [[ -d "$repo/skills" ]]; then
        for d in "$repo/skills"/*/; do
            [[ -d "$d" ]] || continue
            name="$(basename "$d")"
            is_safe_name "$name" || { warn "skipping unsafe skill name: $name"; continue; }
            [[ -f "$d/SKILL.md" ]] || continue
            src="$repo/skills/$name"
            if is_symlink "$src"; then
                resolved="$(canonicalize "$src")"
                [[ "$resolved" == "$repo"/* ]] || { warn "skipping skill symlink leading outside repo: $name -> $resolved"; continue; }
            fi
            entries+=("skill|$name")
        done
    fi

    if ! $SKILLS_ONLY; then
        # commands/
        if [[ -d "$repo/commands" ]]; then
            for f in "$repo/commands"/*.md; do
                [[ -f "$f" || -L "$f" ]] || continue
                local base; base="$(basename "$f" .md)"
                is_safe_name "$base" || { warn "skipping unsafe command name: $base"; continue; }
                if is_symlink "$f"; then
                    resolved="$(canonicalize "$f")"
                    [[ "$resolved" == "$repo"/* ]] || { warn "skipping command symlink leading outside repo: $base -> $resolved"; continue; }
                fi
                entries+=("command|$base")
            done
        fi
        # agents/
        if [[ -d "$repo/agents" ]]; then
            for f in "$repo/agents"/*.md; do
                [[ -f "$f" || -L "$f" ]] || continue
                local base; base="$(basename "$f" .md)"
                is_safe_name "$base" || { warn "skipping unsafe agent name: $base"; continue; }
                if is_symlink "$f"; then
                    resolved="$(canonicalize "$f")"
                    [[ "$resolved" == "$repo"/* ]] || { warn "skipping agent symlink leading outside repo: $base -> $resolved"; continue; }
                fi
                entries+=("agent|$base")
            done
        fi
    fi

    printf "%s\n" "${entries[@]}"
}

# Compute source and target paths for a (kind, name) pair.
# Echo "source_abs<TAB>target_abs<TAB>target_rel"
paths_for() {
    local kind="$1" name="$2"
    local src tgt rel
    case "$kind" in
        skill)
            src="$SKILLS_DIR_ABS/$name"
            rel="$SKILLS_REL/$name"
            tgt="$PROJECT_PATH/$rel" ;;
        command)
            src="$CTS_REPO/commands/$name.md"
            rel="$COMMANDS_REL/$name.md"
            tgt="$PROJECT_PATH/$rel" ;;
        agent)
            src="$CTS_REPO/agents/$name.md"
            rel="$AGENTS_REL/$name.md"
            tgt="$PROJECT_PATH/$rel" ;;
        *)
            die "unknown kind: $kind" ;;
    esac
    printf "%s\t%s\t%s\n" "$src" "$tgt" "$rel"
}

# Parent dir we must ensure exists for a given kind
parent_dir_for_kind() {
    case "$1" in
        skill)   echo "$PROJECT_PATH/$SKILLS_REL" ;;
        command) echo "$PROJECT_PATH/$COMMANDS_REL" ;;
        agent)   echo "$PROJECT_PATH/$AGENTS_REL" ;;
    esac
}

# ─── Manifest I/O ─────────────────────────────────────────────────────────────
# Body line: kind\tname\tsource_rel\ttarget_rel\tmode
load_manifest() {
    local path="$1" out="$2"
    : > "$out"
    [[ -f "$path" ]] || return 0
    local ver; ver="$(awk -F'\t' '$1=="version"{print $2}' "$path" | head -1)"
    [[ "$ver" == "$MANIFEST_VERSION" ]] || die "manifest version mismatch (file: $ver, expected: $MANIFEST_VERSION)"
    awk -F'\t' '
        BEGIN { in_body=0 }
        /^kind\tname\tsource_rel\ttarget_rel\tmode$/ { in_body=1; next }
        in_body && NF==5 { print }
    ' "$path" > "$out"
}

# Lookup by composite key (kind, name) — name alone collides across kinds
manifest_lookup_target() {
    # $1=manifest_data_file $2=kind $3=name → target_rel
    awk -F'\t' -v k="$2" -v n="$3" '$1==k && $2==n {print $4; exit}' "$1"
}

# ─── Resolve project path & cts-repo ──────────────────────────────────────────
PROJECT_PATH="${PROJECT_PATH:-$(pwd)}"
[[ -d "$PROJECT_PATH" ]] || die "project path does not exist: $PROJECT_PATH"
PROJECT_PATH="$(abs_path "$PROJECT_PATH")"
CTS_REPO="$(resolve_cts_repo)"
SKILLS_DIR_ABS="$CTS_REPO/skills"
PROJECT_CTS_DIR="$PROJECT_PATH/$CTS_DIR_NAME"
MANIFEST_PATH="$PROJECT_CTS_DIR/$MANIFEST_NAME"
MANIFEST_PREV="$PROJECT_CTS_DIR/$MANIFEST_PREV_NAME"
LOCK_DIR="$PROJECT_CTS_DIR/$LOCK_DIR_NAME"
DOC_FILE="$PROJECT_PATH/$DOC_FILE_NAME"

# Refuse to install into the cts-repo itself
if [[ "$PROJECT_PATH" == "$CTS_REPO" ]]; then
    die "project path equals cts-repo ($CTS_REPO) — refusing to symlink a repo into itself"
fi

# ─── S9: refuse if parent dirs are themselves symlinks ────────────────────────
check_no_symlinked_parents() {
    local p
    for p in "$PROJECT_CTS_DIR" \
             "$PROJECT_PATH/.claude" \
             "$PROJECT_PATH/$SKILLS_REL" \
             "$PROJECT_PATH/$COMMANDS_REL" \
             "$PROJECT_PATH/$AGENTS_REL" ; do
        if is_symlink "$p"; then
            die "S9: $p is a symlink — refusing to install (would mutate symlink target)"
        fi
    done
}

# ─── Lock acquisition (mkdir-based, portable) ─────────────────────────────────
write_lock_metadata() {
    cat > "$LOCK_DIR/owner.json" <<EOF
{"host":"$(hostname)","pid":$$,"started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","tool":"install_cts.sh"}
EOF
    echo "$$" > "$LOCK_DIR/owner.pid"
    echo "$(hostname)" > "$LOCK_DIR/owner.host"
}

acquire_lock() {
    mkdir -p "$PROJECT_CTS_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        write_lock_metadata
        trap release_lock EXIT INT TERM
        return 0
    fi
    if $CLEAR_STALE_LOCK; then
        local owner=""
        [[ -f "$LOCK_DIR/owner.json" ]] && owner="$(cat "$LOCK_DIR/owner.json")"
        warn "removing stale lock: $LOCK_DIR (was: $owner)"
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" || die "still cannot acquire lock after stale clear"
        write_lock_metadata
        trap release_lock EXIT INT TERM
        return 0
    fi
    local owner=""
    [[ -f "$LOCK_DIR/owner.json" ]] && owner="$(cat "$LOCK_DIR/owner.json")"
    die "another install_cts.sh is running in this project (lock: $LOCK_DIR)
       owner: $owner
       if you are sure no install is in progress, rerun with --clear-stale-lock"
}

release_lock() {
    [[ -d "$LOCK_DIR" ]] || return 0
    if [[ -f "$LOCK_DIR/owner.pid" ]]; then
        local pid; pid="$(cat "$LOCK_DIR/owner.pid" 2>/dev/null || echo "")"
        local host; host="$(cat "$LOCK_DIR/owner.host" 2>/dev/null || echo "")"
        if [[ "$pid" == "$$" && "$host" == "$(hostname)" ]]; then
            rm -rf "$LOCK_DIR"
        fi
    fi
}

# ─── Plan computation ─────────────────────────────────────────────────────────
# Plan line format: ACTION|kind|name|extra
# Actions: CREATE | UPDATE_TARGET | REUSE | REMOVE | ADOPT | CONFLICT
compute_plan() {
    local upstream_file="$1" manifest_data="$2" out="$3"
    : > "$out"
    local kind name src target_path expected_target current_target paths
    while IFS='|' read -r kind name; do
        [[ -z "$name" ]] && continue
        paths="$(paths_for "$kind" "$name")"
        expected_target="$(echo "$paths" | cut -f1)"
        target_path="$(echo "$paths" | cut -f2)"
        if [[ -L "$target_path" ]]; then
            current_target="$(read_link_target "$target_path")"
            if [[ "$current_target" != /* ]]; then
                current_target="$(canonicalize "$(dirname "$target_path")/$current_target")"
            fi
            local in_manifest=false
            if [[ -n "$(manifest_lookup_target "$manifest_data" "$kind" "$name")" ]]; then in_manifest=true; fi
            if [[ "$current_target" == "$expected_target" ]]; then
                if $in_manifest; then echo "REUSE|$kind|$name|" >> "$out"
                else echo "ADOPT|$kind|$name|" >> "$out"
                fi
            else
                if $in_manifest; then
                    echo "UPDATE_TARGET|$kind|$name|$current_target" >> "$out"
                else
                    echo "CONFLICT|$kind|$name|symlink_to:$current_target" >> "$out"
                fi
            fi
        elif [[ -e "$target_path" ]]; then
            echo "CONFLICT|$kind|$name|real_path" >> "$out"
        else
            echo "CREATE|$kind|$name|" >> "$out"
        fi
    done < "$upstream_file"

    # Manifest entries no longer in upstream → REMOVE
    while IFS=$'\t' read -r mkind mname msrc mtarget mmode; do
        [[ -z "$mname" ]] && continue
        if grep -q "^$mkind|$mname$" "$upstream_file"; then continue; fi
        echo "REMOVE|$mkind|$mname|" >> "$out"
    done < "$manifest_data"
}

# Apply --adopt-existing / --replace-link allowlists by mutating plan lines
apply_allowlists() {
    local plan="$1"
    local key kind name
    # --adopt-existing kind:name → if CONFLICT with current target == expected, convert to ADOPT
    for key in "${ADOPT_KEYS[@]:-}"; do
        [[ -z "$key" ]] && continue
        kind="${key%%:*}"; name="${key#*:}"
        local paths expected; paths="$(paths_for "$kind" "$name")"
        expected="$(echo "$paths" | cut -f1)"
        # only act on lines where extra=="symlink_to:$expected"
        local pattern="^CONFLICT|$kind|$name|symlink_to:$expected\$"
        local replace="ADOPT|$kind|$name|"
        local tmp; tmp="$(mktemp -t cts-plan.XXXX)"
        awk -F'|' -v p="$pattern" -v r="$replace" '
            { line=$0 }
            line ~ p { print r; next }
            { print line }
        ' "$plan" > "$tmp"
        mv -f "$tmp" "$plan"
    done
    # --replace-link kind:name → convert CONFLICT|symlink_to:* to UPDATE_TARGET
    for key in "${REPLACE_LINK_KEYS[@]:-}"; do
        [[ -z "$key" ]] && continue
        kind="${key%%:*}"; name="${key#*:}"
        local tmp; tmp="$(mktemp -t cts-plan.XXXX)"
        awk -F'|' -v k="$kind" -v n="$name" '
            BEGIN { OFS="|" }
            $1=="CONFLICT" && $2==k && $3==n && $4 ~ /^symlink_to:/ {
                sub(/^symlink_to:/, "", $4)
                print "UPDATE_TARGET", k, n, $4
                next
            }
            { print $0 }
        ' "$plan" > "$tmp"
        mv -f "$tmp" "$plan"
    done
}

# ─── Plan rendering ───────────────────────────────────────────────────────────
print_plan() {
    local plan="$1"
    local n_create n_update n_reuse n_remove n_adopt n_conflict
    n_create=$(grep -c '^CREATE|' "$plan" || true)
    n_update=$(grep -c '^UPDATE_TARGET|' "$plan" || true)
    n_reuse=$(grep -c '^REUSE|' "$plan" || true)
    n_remove=$(grep -c '^REMOVE|' "$plan" || true)
    n_adopt=$(grep -c '^ADOPT|' "$plan" || true)
    n_conflict=$(grep -c '^CONFLICT|' "$plan" || true)
    log ""
    log "Plan summary:"
    log "  CREATE:        $n_create  (new symlinks to add)"
    log "  ADOPT:         $n_adopt   (orphan symlinks already pointing to correct target)"
    log "  UPDATE_TARGET: $n_update  (managed symlinks with stale target)"
    log "  REUSE:         $n_reuse   (already correct, no-op)"
    log "  REMOVE:        $n_remove  (in old manifest, no longer upstream)"
    log "  CONFLICT:      $n_conflict  (must be resolved before apply)"
    if (( n_conflict > 0 )); then
        log ""
        log "Conflicts (need user action):"
        grep '^CONFLICT|' "$plan" | while IFS='|' read -r _ kind name extra; do
            log "  - $kind:$name → $extra"
        done
    fi
}

# ─── Apply ────────────────────────────────────────────────────────────────────
write_manifest_tmp() {
    local plan="$1" out="$2"
    {
        printf "version\t%s\n" "$MANIFEST_VERSION"
        printf "repo_root\t%s\n" "$CTS_REPO"
        printf "project_root\t%s\n" "$PROJECT_PATH"
        printf "generated\t%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf "kind\tname\tsource_rel\ttarget_rel\tmode\n"
        awk -F'|' '$1=="REUSE"||$1=="ADOPT"||$1=="CREATE"||$1=="UPDATE_TARGET"{print $0}' "$plan" \
        | while IFS='|' read -r action kind name _; do
            local src_rel tgt_rel
            case "$kind" in
                skill)   src_rel="skills/$name";          tgt_rel="$SKILLS_REL/$name" ;;
                command) src_rel="commands/$name.md";     tgt_rel="$COMMANDS_REL/$name.md" ;;
                agent)   src_rel="agents/$name.md";       tgt_rel="$AGENTS_REL/$name.md" ;;
            esac
            printf "%s\t%s\t%s\t%s\tsymlink\n" "$kind" "$name" "$src_rel" "$tgt_rel"
        done
    } > "$out"
}

apply_plan() {
    local plan="$1"
    local action kind name extra paths expected_target target_path parent
    while IFS='|' read -r action kind name extra; do
        [[ -z "$name" ]] && continue
        paths="$(paths_for "$kind" "$name")"
        expected_target="$(echo "$paths" | cut -f1)"
        target_path="$(echo "$paths" | cut -f2)"
        parent="$(parent_dir_for_kind "$kind")"
        case "$action" in
            REUSE|ADOPT)
                : # nothing to do
                ;;
            CREATE)
                if [[ -e "$target_path" || -L "$target_path" ]]; then
                    die "S4 violation: $target_path appeared between plan and apply"
                fi
                if $DRY_RUN; then log "  (dry-run) ln -s $expected_target $target_path"
                else
                    mkdir -p "$parent"
                    ln -s "$expected_target" "$target_path"
                    log "  + $kind:$name"
                fi
                ;;
            UPDATE_TARGET)
                local plan_saw_target; plan_saw_target="$(read_link_target "$target_path" 2>/dev/null || echo "")"
                [[ "$plan_saw_target" != /* && -n "$plan_saw_target" ]] && plan_saw_target="$(canonicalize "$(dirname "$target_path")/$plan_saw_target")"
                if [[ "$plan_saw_target" != "$extra" ]]; then
                    warn "S11: $target_path target changed since plan ($plan_saw_target vs $extra) — skipping"
                    continue
                fi
                if [[ "$plan_saw_target" != "$CTS_REPO"/* ]]; then
                    warn "S2: refusing to replace symlink pointing outside cts-repo: $target_path -> $plan_saw_target"
                    continue
                fi
                if $DRY_RUN; then log "  (dry-run) update target: $target_path -> $expected_target"
                else
                    rm -f "$target_path"
                    ln -s "$expected_target" "$target_path"
                    log "  ↻ $kind:$name"
                fi
                ;;
            REMOVE)
                is_symlink "$target_path" || { warn "S1: $target_path is not a symlink, refusing to remove"; continue; }
                local cur; cur="$(read_link_target "$target_path")"
                [[ "$cur" != /* ]] && cur="$(canonicalize "$(dirname "$target_path")/$cur")"
                [[ "$cur" == "$CTS_REPO"/* ]] || { warn "S2: $target_path target $cur outside cts-repo, refusing"; continue; }
                if $DRY_RUN; then log "  (dry-run) rm $target_path"
                else rm -f "$target_path"; log "  - $kind:$name"
                fi
                ;;
            CONFLICT)
                die "BUG: CONFLICT $kind:$name reached apply phase"
                ;;
        esac
    done < "$plan"
}

commit_manifest() {
    local manifest_tmp="$1"
    if $DRY_RUN; then log "  (dry-run) would commit manifest"; return; fi
    if [[ -f "$MANIFEST_PATH" ]]; then
        cp -p "$MANIFEST_PATH" "$MANIFEST_PREV.tmp"
        mv -f "$MANIFEST_PREV.tmp" "$MANIFEST_PREV"
    fi
    mv -f "$manifest_tmp" "$MANIFEST_PATH"
}

# ─── CLAUDE.md best-effort update (compare-and-swap) ──────────────────────────
update_claude_doc() {
    local installed_count="$1"
    [[ -f "$DOC_FILE" ]] || { log "  (skip CLAUDE.md: file not present)"; return 0; }
    if $NO_DOC; then return 0; fi

    local original new_block tmp
    original="$(cat "$DOC_FILE")"
    new_block="$BLOCK_BEGIN
## claude-trading-skills Scope
Trading skills installed in this project: $installed_count entries.
Manifest: \`$CTS_DIR_NAME/$MANIFEST_NAME\` (lists every entry CTS installed and its upstream target).
Prefer the project-local entries under \`$SKILLS_REL/\`, \`$COMMANDS_REL/\`, and \`$AGENTS_REL/\` over global ones.
Do not modify or delete files inside any entry that is a symlink (symlinks point into \`$CTS_REPO\`).
Update with: \`bash $CTS_REPO/tools/install_cts.sh\`  (re-runnable; reconciles new/removed entries).
$BLOCK_END"

    local new_content
    if printf '%s' "$original" | grep -qF "$BLOCK_BEGIN"; then
        new_content="$(python3 - "$DOC_FILE" "$BLOCK_BEGIN" "$BLOCK_END" "$new_block" <<'PYEOF'
import re, sys, pathlib
path, begin, end, body = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = pathlib.Path(path).read_text()
pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
matches = pattern.findall(text)
if len(matches) > 1:
    sys.stderr.write("CTS:WARN multiple CTS blocks found in CLAUDE.md; skipping update\n")
    sys.stdout.write(text)
else:
    sys.stdout.write(pattern.sub(body, text))
PYEOF
        )" || { warn "CLAUDE.md update failed (best-effort, continuing)"; return 0; }
    else
        new_content="$original"
        [[ -n "$original" ]] && new_content="${new_content}"$'\n'
        new_content="${new_content}${new_block}"$'\n'
    fi

    if $DRY_RUN; then log "  (dry-run) would update CLAUDE.md CTS block"; return 0; fi
    tmp="$DOC_FILE.cts-tmp.$$"
    printf '%s' "$new_content" > "$tmp"
    local current; current="$(cat "$DOC_FILE")"
    if [[ "$current" != "$original" ]]; then
        rm -f "$tmp"
        warn "CLAUDE.md changed during install — skipping doc update (rerun to retry)"
        return 0
    fi
    mv -f "$tmp" "$DOC_FILE"
    log "  ✓ updated CLAUDE.md (CTS managed block)"
}

# ─── Uninstall ────────────────────────────────────────────────────────────────
do_uninstall() {
    [[ -f "$MANIFEST_PATH" ]] || die "no manifest at $MANIFEST_PATH; nothing to uninstall"
    local manifest_data; manifest_data="$(mktemp -t cts-manifest.XXXX)"
    load_manifest "$MANIFEST_PATH" "$manifest_data"
    log ""
    log "Uninstall plan:"
    while IFS=$'\t' read -r kind name src target mode; do
        [[ -z "$name" ]] && continue
        log "  - $kind:$name"
    done < "$manifest_data"
    if ! $DRY_RUN && ! $QUIET; then
        prompt "Proceed?" || { log "aborted"; exit 0; }
    fi
    while IFS=$'\t' read -r kind name src target mode; do
        [[ -z "$name" ]] && continue
        local target_path="$PROJECT_PATH/$target"
        local paths expected
        paths="$(paths_for "$kind" "$name")"
        expected="$(echo "$paths" | cut -f1)"
        is_symlink "$target_path" || { warn "S1: $target_path not a symlink, skipping"; continue; }
        local cur; cur="$(read_link_target "$target_path")"
        [[ "$cur" != /* ]] && cur="$(canonicalize "$(dirname "$target_path")/$cur")"
        if [[ "$cur" != "$expected" ]]; then
            warn "S8: $target_path target $cur != expected $expected, skipping"
            continue
        fi
        if $DRY_RUN; then log "  (dry-run) rm $target_path"
        else rm -f "$target_path"; log "  - removed $kind:$name"
        fi
    done < "$manifest_data"
    rm -f "$manifest_data"
    if ! $DRY_RUN; then
        [[ -f "$MANIFEST_PATH" ]] && mv -f "$MANIFEST_PATH" "$MANIFEST_PREV"
        log "  ✓ uninstalled (manifest preserved as $MANIFEST_PREV)"
    fi
}

# ─── Main flow ────────────────────────────────────────────────────────────────
log ""
log "claude-trading-skills Project Install"
log "  Project:    $PROJECT_PATH"
log "  CTS repo:   $CTS_REPO"
log "  Action:     $ACTION$($DRY_RUN && echo ' (dry-run)')"
log ""

check_no_symlinked_parents
acquire_lock

if [[ "$ACTION" == "uninstall" ]]; then
    do_uninstall
    exit 0
fi

if [[ "$ACTION" == "reconcile" && ! -f "$MANIFEST_PATH" ]]; then
    die "--reconcile requires existing manifest; none found at $MANIFEST_PATH"
fi

UPSTREAM_FILE="$(mktemp -t cts-upstream.XXXX)"
build_upstream_inventory "$CTS_REPO" > "$UPSTREAM_FILE"
[[ -s "$UPSTREAM_FILE" ]] || die "upstream inventory empty (broken cts-repo?)"

MANIFEST_DATA="$(mktemp -t cts-manifest.XXXX)"
load_manifest "$MANIFEST_PATH" "$MANIFEST_DATA"

PLAN_FILE="$(mktemp -t cts-plan.XXXX)"
compute_plan "$UPSTREAM_FILE" "$MANIFEST_DATA" "$PLAN_FILE"
apply_allowlists "$PLAN_FILE"
print_plan "$PLAN_FILE"

N_CONFLICT=$(grep -c '^CONFLICT|' "$PLAN_FILE" || true)
if (( N_CONFLICT > 0 )); then
    log ""
    log "Aborting due to $N_CONFLICT unresolved conflicts."
    log "Resolve options per entry (kind:name):"
    log "  - back up & remove the conflicting path manually, then rerun"
    log "  - if it's a foreign symlink that should be adopted: --adopt-existing kind:name"
    log "  - if it's a stale managed symlink with wrong target: --replace-link kind:name"
    exit 1
fi

if $DRY_RUN; then
    log ""
    log "(dry-run) no changes made"
    exit 0
fi

N_CHANGES=$(awk -F'|' '$1=="CREATE"||$1=="UPDATE_TARGET"||$1=="REMOVE"' "$PLAN_FILE" | wc -l | tr -d ' ')
if (( N_CHANGES > 0 )) && ! $QUIET; then
    prompt "Apply these $N_CHANGES changes?" || { log "aborted"; exit 0; }
fi

MANIFEST_TMP="$MANIFEST_PATH.tmp.$$"
mkdir -p "$PROJECT_CTS_DIR"
write_manifest_tmp "$PLAN_FILE" "$MANIFEST_TMP"
log ""
log "Applying:"
apply_plan "$PLAN_FILE"
commit_manifest "$MANIFEST_TMP"

INSTALLED_COUNT=$(awk -F'|' '$1=="REUSE"||$1=="ADOPT"||$1=="CREATE"||$1=="UPDATE_TARGET"' "$PLAN_FILE" | wc -l | tr -d ' ')
update_claude_doc "$INSTALLED_COUNT"

if ! $DRY_RUN; then
    BAD=0
    while IFS=$'\t' read -r v_kind v_name v_src v_target v_mode; do
        [[ -z "$v_name" ]] && continue
        VTARGET="$PROJECT_PATH/$v_target"
        if ! is_symlink "$VTARGET"; then warn "verify: $VTARGET missing"; BAD=$((BAD+1)); fi
    done < <(awk -F'\t' '
        BEGIN { in_body=0 }
        /^kind\tname\tsource_rel\ttarget_rel\tmode$/ { in_body=1; next }
        in_body && NF==5 { print }
    ' "$MANIFEST_PATH")
    (( BAD == 0 )) && log "" && log "✓ Install complete. $N_CHANGES changes applied."
fi

rm -f "$UPSTREAM_FILE" "$MANIFEST_DATA" "$PLAN_FILE"
