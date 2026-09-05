# claude-remote-launcher

A tiny skill + CLI that spawns a Claude Code [Remote Control](https://code.claude.com/docs/en/remote-control) session in a detached `tmux` pane. By default it just confirms the session started (the remote chat appears on your device); pass `--url` to also print the `claude.ai/code` link.

Designed so an agent (or you) can launch fresh Claude sessions in existing or brand-new project folders without leaving the current session. The skill is wired up for **Claude Code, Cursor, Codex and Gemini** from one source (see [Install](#install)).

## Install

Install the skill via the plugin (option 1 or 2); add the standalone shell CLI (option 3) if you also want to run `claude-remote` by hand.

### 1. As a Claude Code plugin (this repo is its own marketplace)

```text
/plugin marketplace add superbereza/claude-remote-launcher
/plugin install claude-remote@claude-remote-launcher
```

### 2. From an aggregate marketplace

```text
/plugin marketplace add superbereza/superbereza-skills
/plugin install claude-remote@superbereza-skills
```

### 3. The `claude-remote` CLI on your own shell (optional)

```bash
git clone https://github.com/superbereza/claude-remote-launcher ~/dev/claude-remote-launcher
cd ~/dev/claude-remote-launcher
./scripts/install.sh   # symlinks ~/.local/bin/claude-remote → bin/claude-remote (~/.local/bin must be on PATH)
```

For running `claude-remote` by hand (incl. on a remote server). The skill comes from the plugin (option 1/2), so `scripts/install.sh` only puts the CLI on PATH — it doesn't symlink the skill.

### Other agents

The same `skills/` directory is exposed to **Cursor** (`.cursor-plugin/`), **Codex** (`.codex-plugin/`) and **Gemini** (`gemini-extension.json` → [`AGENTS.md`](AGENTS.md)). One skill, one source — see [`AGENTS.md`](AGENTS.md).

## Usage

```bash
# Existing folder — chat title defaults to the folder name
claude-remote spawn ~/dev/myproject

# New folder (auto-created and pre-trusted)
claude-remote spawn ~/dev/scratch-experiment

# Custom session name (= the remote-control chat title, used verbatim)
claude-remote spawn ~/dev/myproject debug-auth

# Also print the claude.ai/code URL
claude-remote spawn ~/dev/myproject --url

# Seed the new chat with a starting task (typed in + submitted once it's up)
claude-remote spawn ~/dev/myproject --prompt "scaffold a FastAPI service with a health check"

# Send a message into a session that's ALREADY running
claude-remote send 'cc—myproject' "run the tests and summarize failures"
```

Default output (status only):
```
SESSION: cc—myproject
STATUS:  remote-control active
ATTACH:  tmux attach -t 'cc—myproject'
```

With `--url` the `STATUS` line becomes `URL: https://claude.ai/code/...`. The success signal is Remote Control coming up (its status bar **or** a `bridgeSessionId` in the session's state file) — exit code is `1` only if RC doesn't activate; a missing `--url` link while RC is active is **not** a failure. Newer Claude auto-attaches Remote Control, so you rarely need the URL at all.

## Subcommands

| Command | Action |
|---------|--------|
| `claude-remote spawn <path> [name] [--url] [--prompt <text>]` | Spawn a session in `<path>`. **The `spawn` verb is required** — no bare `claude-remote <path>` shortcut (it used to turn a typo'd subcommand into a junk session). |
| `claude-remote ls` | List running `cc—` tmux sessions |
| `claude-remote send [--raw] <session> <text…>` | Send a message into an **existing** session and submit it (drive a live chat; `--prompt` seeds a *new* one). Prefixes a `[from <you> — to reply: …]` header so the receiver can answer back; `--raw` omits it |
| `claude-remote kill <session>` | Kill one |
| `claude-remote kill --all` | Kill all `cc—` sessions |
| `claude-remote self-close` | From **inside** a session: deregister from [claude-keep](https://github.com/superbereza/claude-session-keeper) (if tracked) then kill its own tmux |
| `claude-remote refresh <session>` | Re-issue `/remote-control` inside an existing pane → fresh URL, same chat |
| `claude-remote help` / `--version` | Show usage / print version |

The session `name` is the remote-control chat title, **used verbatim** — nothing is
prepended automatically, so include a `device/` prefix yourself if you use that
convention (e.g. `claude-remote spawn ~/dev/x "mac-mini/x"`).

Disconnecting from claude.ai/code only drops the remote view; the local `claude` process keeps running until you kill the tmux session. The trust entry written to `~/.claude.json` is left in place after killing sessions, so re-launching in the same folder is fast.

## How it works

1. Resolves the absolute path and detects whether the folder is new.
2. Creates the folder with `mkdir -p` if missing.
3. **Pre-trusts the folder** by atomically writing `hasTrustDialogAccepted: true` into `~/.claude.json` under the project entry.
4. Starts a detached tmux session in the folder.
5. Runs `claude --remote-control "<name>" --dangerously-skip-permissions` inside the pane — Remote Control is enabled **and named at launch** via the flag (name defaults to the folder). This replaced a post-launch `/remote-control <name>` slash: newer Claude auto-attaches RC on startup with a *derived* name before the slash could run, and a slash on an already-active RC only opens the management dialog (ignoring the name) — so the chat kept the wrong title and any seed prompt was lost in the race.
6. Waits for `bypass permissions on` (bottom-bar indicator) — the TUI is ready. Trust dialog is skipped thanks to step 3.
7. Confirms Remote Control came up (status bar **or** a `bridgeSessionId` in the state file).
8. Polls `tmux capture-pane` (with `-J` to join wrapped lines) for `https://claude.ai/code/...` (timeout 30 s) to confirm it came up.
9. Prints the status (or the URL with `--url`). Tmux session keeps running after the script exits.

## Why slash command, not server mode

`claude remote-control` (server mode) bundles all sessions inside a single process — when the server's OAuth token rotates (~24 h), the daemon dies and takes every session with it (see [#53635](https://github.com/anthropics/claude-code/issues/53635), [#53563](https://github.com/anthropics/claude-code/issues/53563)).

The slash-command approach this script uses keeps the conversation as a plain Claude session backed by `<uuid>.jsonl`. If Remote Control drops, run `claude-remote refresh <session>` to re-issue `/remote-control` inside the existing tmux pane — fresh URL, history preserved. If the `claude` process itself dies, you can `claude --resume <uuid> --dangerously-skip-permissions` and `/remote-control` again.

## Requirements

- `claude` ≥ 2.1.51 (Remote Control support), logged in with a Claude subscription
- `tmux`
- `python3` (used for absolute-path resolution and atomic JSON edits)

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the `~/.local/bin/claude-remote` symlink. Repo and `~/.claude.json` are not touched.

## OpenCode

This skill also supports [OpenCode](https://opencode.ai) — see [`.opencode/INSTALL.md`](.opencode/INSTALL.md).
