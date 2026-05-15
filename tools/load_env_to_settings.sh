#!/usr/bin/env bash
# load_env_to_settings.sh — Merge a `.env` file into `.claude/settings.local.json`.
#
# Claude Code applies the `env` field of `settings.local.json` to every Bash
# tool call. This script reads the `.env` in the current directory (or one
# passed via --env-file) and merges its `export KEY="value"` lines into the
# settings.local.json `env` block, preserving any other settings already there.
#
# Usage:
#   cd /path/to/your/project
#   bash /path/to/claude-trading-skills/tools/load_env_to_settings.sh
#
# Options:
#   --env-file PATH          path to .env (default: ./.env)
#   --settings-file PATH     path to settings.local.json (default: ./.claude/settings.local.json)
#   --dry-run                print resulting JSON to stdout, don't write
#   --quiet                  suppress informational logs

set -euo pipefail

ENV_FILE="./.env"
SETTINGS_FILE="./.claude/settings.local.json"
DRY_RUN=false
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)      ENV_FILE="${2:?--env-file requires path}"; shift 2 ;;
        --settings-file) SETTINGS_FILE="${2:?--settings-file requires path}"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --quiet)         QUIET=true; shift ;;
        -h|--help)       sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)               echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

log() { $QUIET && return 0; echo "$@"; }
die() { echo "error: $*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE
       run from your project root (where .env lives), or pass --env-file PATH"

command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH"

# Use python for robust JSON merge (preserves existing keys, handles quoting
# and inline comments). Outputs merged JSON on stdout.
PYOUT="$(python3 - "$ENV_FILE" "$SETTINGS_FILE" <<'PYEOF'
import json
import re
import sys
from pathlib import Path

env_path = Path(sys.argv[1])
settings_path = Path(sys.argv[2])

# Match KEY=VALUE with three value forms:
#   "double-quoted"  | 'single-quoted'  | bareword (up to # comment or EOL)
# `export` prefix optional. Trailing `# comment` allowed in all forms.
env_re = re.compile(
    r'^\s*(?:export\s+)?'
    r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'
    r'(?:"((?:[^"\\]|\\.)*)"'        # group 2: double-quoted (escapes preserved as-is)
    r"|'([^']*)'"                    # group 3: single-quoted
    r'|([^\s#]*))'                   # group 4: bareword (no whitespace or #)
    r'\s*(?:#.*)?$'
)
new_env, skipped = {}, []
for raw in env_path.read_text().splitlines():
    s = raw.strip()
    if not s or s.startswith("#"):
        continue
    m = env_re.match(raw)
    if not m:
        continue
    key = m.group(1)
    val = m.group(2) if m.group(2) is not None else (m.group(3) if m.group(3) is not None else m.group(4))
    if not val:
        skipped.append(key)
        continue
    new_env[key] = val

if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text())
    except json.JSONDecodeError as e:
        sys.stderr.write(f"error: existing {settings_path} is not valid JSON: {e}\n")
        sys.exit(1)
else:
    settings = {}

existing_env = settings.get("env", {})
if not isinstance(existing_env, dict):
    sys.stderr.write(f"error: existing 'env' field in {settings_path} is not an object\n")
    sys.exit(1)

settings["env"] = {**existing_env, **new_env}  # .env wins over existing
sys.stdout.write(json.dumps(settings, indent=2, sort_keys=True) + "\n")
PYEOF
)"

[[ -n "$PYOUT" ]] || die "python helper produced no output"

# Number of resulting env keys (for the log line)
COUNT="$(printf '%s' "$PYOUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("env",{})))')"

if $DRY_RUN; then
    log "(dry-run) would write to: $SETTINGS_FILE"
    log "(dry-run) merged env keys: $COUNT"
    log ""
    printf '%s' "$PYOUT"
    exit 0
fi

mkdir -p "$(dirname "$SETTINGS_FILE")"
TMP="$SETTINGS_FILE.tmp.$$"
printf '%s' "$PYOUT" > "$TMP"
mv -f "$TMP" "$SETTINGS_FILE"

log "✓ wrote $SETTINGS_FILE ($COUNT env keys merged)"
log ""
log "Verify with:"
log "  cat $SETTINGS_FILE"
log ""
log "In Claude Code, every Bash tool call will now inherit these env vars."
