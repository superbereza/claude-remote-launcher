# claude-remote-launcher — agent guide

Spawn, message and close **Claude Code Remote Control** sessions on **tmux** or **herdr**
(pluggable backend picked from `~/.config/claude-remote/config.toml`, `auto` by default). By default
`spawn` just confirms the session started (the remote chat appears on the user's device); `--url`
also prints the `claude.ai/code` link. Second skill: **herdr-migration** (tmux → herdr, nothing lost).

The same skills are wired up for several coding agents from one source:

- **Claude Code / Cursor / Codex** — [`skills/claude-remote/SKILL.md`](skills/claude-remote/SKILL.md),
  [`skills/herdr-migration/SKILL.md`](skills/herdr-migration/SKILL.md) (auto-discovered via
  `.claude-plugin/`, `.cursor-plugin/`, `.codex-plugin/`).
- **Gemini** — reads this file (`gemini-extension.json` → `contextFileName: AGENTS.md`).

Requires `claude` (v2.1.51+, logged in), `python3`, and `tmux` and/or `herdr`.

## Cheat sheet

```bash
claude-remote spawn <path> [name] [--prompt TEXT | --prompt-file F] [--model M] [--effort E] [--url]
claude-remote ls                              # sessions on every available backend
claude-remote send [--raw] <session> <text…>  # message a LIVE session (from/reply header; --raw omits)
claude-remote kill <session> | --all          # close (claude process included)
claude-remote self-close                      # from INSIDE a session: deregister from claude-keep + close itself
claude-remote refresh <session>               # re-issue /remote-control for a fresh URL
claude-remote heal [--dry-run]                # herdr: restore titles/flags after a herdr restart
claude-remote config show                     # settings: backend, rc_prefix, permission_mode, model, …
claude-remote --backend tmux|herdr <cmd>      # override the backend for one call
```

## Layout

`bin/claude-remote` = core (settings, arg parsing, dispatch) → `lib/backend-tmux.sh`,
`lib/backend-herdr.sh` (+ `lib/herdr_helper.py`) implement one contract (documented at the top of
`lib/backend-tmux.sh`). `lib/config.py` loads settings. New runtime = new `lib/backend-<name>.sh`.

## Maintainer note

Changing a skill or its payload? It reaches installed plugins **only after a release** —
`scripts/bump.sh <v>` → commit → tag `vX.Y.Z` → GitHub release → `/plugin update`. A commit on
`main` alone propagates nothing (Claude/Codex cache plugins by version string). Full rule and the
MAJOR/MINOR/PATCH guidance: the `skill-builder` skill, §7.
