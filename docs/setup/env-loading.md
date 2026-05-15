---
title: Auto-loading API keys
---

# Auto-loading API keys in Claude Code

The trading skills read API keys from environment variables (`FMP_API_KEY`,
`FINVIZ_API_KEY`, `ALPACA_API_KEY`, etc.). The skill scripts themselves do
**not** call `python-dotenv` or otherwise load a `.env` file — that's the
caller's job.

Claude Code's Bash tool spawns a fresh shell per tool call (working directory
persists, shell state does not), so a one-time `source .env` won't carry
across tool invocations. You need a mechanism that injects env vars into
**every** Bash tool call.

## Recommended: `.claude/settings.local.json` (Claude Code-native)

Claude Code applies the `env` field of `settings.json` / `settings.local.json`
to every Bash tool call. `settings.local.json` is gitignored by default, so
secrets stay out of version control.

```json
{
  "env": {
    "FMP_API_KEY": "your_fmp_key_here",
    "FINVIZ_API_KEY": "your_finviz_key_here",
    "ALPACA_API_KEY": "your_alpaca_key_id",
    "ALPACA_SECRET_KEY": "your_alpaca_secret",
    "ALPACA_PAPER": "true"
  }
}
```

**Generate it from your `.env`** with the helper:

```bash
bash /Users/anhar/codes/claude-trading-skills/tools/load_env_to_settings.sh
```

The helper reads `.env` in the current directory and merges its exports into
`.claude/settings.local.json` (preserving any other settings already there).
Re-run it whenever you rotate keys.

This is the right choice for **Claude Code Remote Control** — there's no
shell to integrate with, and `settings.local.json` is read at session start.

## Alternative 1: direnv (best for mixed CLI + Claude Code use)

If you also run skills directly from the terminal, direnv auto-loads
`.envrc` whenever you `cd` into the project.

```bash
brew install direnv          # or: apt install direnv
# Add to ~/.zshrc (or ~/.bashrc):  eval "$(direnv hook zsh)"

cd /path/to/your/project
cp /Users/anhar/codes/claude-trading-skills/.env.example .envrc
# edit .envrc with your keys
direnv allow
```

Claude Code's Bash tool inherits the parent shell's PATH, so if direnv is
hooked into your shell *and* Claude Code is launched from a directory where
direnv has loaded, the vars come along. Less robust than the settings.json
approach for headless / remote use.

## Alternative 2: per-command CLI flags

Skip env vars entirely and pass keys per invocation:

```bash
python3 .claude/skills/economic-calendar-fetcher/scripts/get_economic_calendar.py \
  --api-key "$FMP_API_KEY_FROM_SOMEWHERE"
```

Works, but you'll thread the key through every Claude prompt — tedious.

## Verifying it works

After setting up, ask Claude Code:

> Run `env | grep -E '^(FMP|FINVIZ|ALPACA)_'` and confirm which keys are set.

If the relevant vars print, the auto-load is working.

## Security notes

- `.env`, `.envrc`, and `.claude/settings.local.json` are all gitignored in
  the cts-repo. **Verify your downstream project's `.gitignore` covers them
  too** before committing anything.
- Never paste API keys into `CLAUDE.md`, `README.md`, or skill output files —
  these are committed.
- For Alpaca, start with paper trading (`ALPACA_PAPER=true`) until you've
  verified the MCP wiring end-to-end.
