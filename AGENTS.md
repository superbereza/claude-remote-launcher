# claude-remote-launcher — agent guide

Spin up a fresh **Claude Code Remote Control** session in any folder, in a detached
`tmux` pane. By default it just confirms the session started (the remote chat appears
on the user's device); pass `--url` to also print the `claude.ai/code` link.

The same skill is wired up for several coding agents from one source:

- **Claude Code / Cursor / Codex** — load the skill at [`skills/claude-remote/SKILL.md`](skills/claude-remote/SKILL.md)
  (auto-discovered via `.claude-plugin/`, `.cursor-plugin/`, `.codex-plugin/`).
- **Gemini** — reads this file (`gemini-extension.json` → `contextFileName: AGENTS.md`).
- Full, authoritative usage: [`skills/claude-remote/SKILL.md`](skills/claude-remote/SKILL.md).

Requires `tmux`, `claude` (v2.1.51+, logged in), and `python3`.

## Invoking the CLI

Call `claude-remote` directly. It's a self-contained bash script — no build/venv step.

## Cheat sheet

```bash
claude-remote <path> [name]          # spawn a session; name defaults to the folder
claude-remote <path> [name] --url    # also print the claude.ai/code URL
claude-remote <path> [name] --prompt "fix the failing tests"   # seed the new chat with a starting task
claude-remote ls                     # list running cc— tmux sessions
claude-remote send <session> <text…> # send a message into an EXISTING session and submit it
claude-remote kill <session>         # kill one session
claude-remote kill --all             # kill all cc— sessions
claude-remote self-close             # from INSIDE a session: deregister from claude-keep (if tracked) + kill own tmux
claude-remote refresh <session>      # re-issue /remote-control for a fresh URL
```

The session `name` is the remote-control chat title (passed verbatim — include a
`device/` prefix yourself if you use that convention). Default behaviour prints a
status, not the URL — read the skill for details.
## Maintainer note

Changing a skill or its payload? It reaches installed plugins **only after a release** —
`scripts/bump.sh <v>` → commit → tag `vX.Y.Z` → GitHub release → `/plugin update`. A commit on
`main` alone propagates nothing (Claude/Codex cache plugins by version string). Full rule and the
MAJOR/MINOR/PATCH guidance: the `skill-builder` skill, §7.
