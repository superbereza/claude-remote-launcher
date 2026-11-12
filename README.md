# claude-remote-launcher

A small skill + CLI that spawns, messages and closes Claude Code [Remote Control](https://code.claude.com/docs/en/remote-control) sessions — on **tmux** or **[herdr](https://herdr.dev)** (pluggable backend, chosen in a settings file). By default `spawn` just confirms the session started (the remote chat appears on your device); pass `--url` to also print the `claude.ai/code` link. A second skill, **herdr-migration**, moves a machine's sessions from tmux to herdr without losing a conversation.

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
claude-remote spawn ~/dev/myproject                          # chat title = <rc_prefix>myproject
claude-remote spawn ~/dev/myproject debug-auth --model opus  # custom title + model
claude-remote spawn ~/dev/myproject --prompt "scaffold a FastAPI service"   # seed a first task
claude-remote spawn ~/dev/myproject --prompt-file seed.txt   # long multi-line seed, any quotes
claude-remote ls                                             # every backend
claude-remote send debug-auth "run the tests and summarize failures"
claude-remote kill debug-auth
claude-remote heal                                           # herdr: restore titles/flags after a herdr restart
claude-remote config show                                    # effective settings + where each came from
```

Output:
```
SESSION: dev-serv-in/myproject
BACKEND: herdr (agent myproject, pane w4:p1, workspace w4)
STATUS:  remote-control active
ATTACH:  herdr agent attach myproject
```
Exit code `1` only if Remote Control doesn't come up within 45 s (signal: a `bridgeSessionId` in Claude's state file, or the RC status bar — not the URL).

## Backends

| backend | a session is | picked when |
|---|---|---|
| `herdr` | a herdr workspace; claude started with `herdr agent start` (named agent, auto-resumed by herdr after a restart) | `backend = "herdr"`, or `auto` and the herdr server is running |
| `tmux` | a detached tmux session `cc—<title>` | `backend = "tmux"`, or `auto` without herdr |

`auto` is the default; `--backend tmux|herdr` overrides it per call. Lookups (`send`, `kill`, `ls`, `refresh`) search every available backend. Each backend is one file, `lib/backend-<name>.sh`, implementing the same small contract (spawn / ls / resolve / send / kill / refresh / self-close / whoami) — adding another runtime means adding one file.

## Settings

`~/.config/claude-remote/config.toml` — `claude-remote config init` writes [`config.example.toml`](config.example.toml) (the author's own defaults). Precedence: built-in default < file < `CLAUDE_REMOTE_<KEY>` env < flag.

| key | built-in default | |
|---|---|---|
| `backend` | `auto` | `auto` / `tmux` / `herdr` |
| `rc_prefix` | `""` | prepended to chat titles without a `/`, e.g. `dev-serv-in/` |
| `permission_mode` | `bypass` | `bypass` (`--dangerously-skip-permissions`) / `auto` / `acceptEdits` / `default` / `plan` |
| `model`, `effort` | `""` | defaults for new sessions |
| `claude_bin`, `herdr_bin` | `""` | override auto-detected paths |
| `message_header` | `[from {from} — to reply: claude-remote send '{from}' "<your answer>"]` | prefix of `send` messages |

## Subcommands

| Command | Action |
|---------|--------|
| `spawn <path> [name] [flags]` | New session. Flags: `--prompt`/`--prompt-file`, `--resume <uuid>`, `--model`, `--effort`, `--permission-mode`, `--url`. The `spawn` verb is required (no implicit spawn — typos never create junk sessions). |
| `ls` | Running sessions, all backends |
| `send [--raw] <session> <text…>` | Message a live session, prefixed with a from/reply header (`--raw` omits it) |
| `kill <session>` / `kill --all` | Close; the claude process is made sure to be gone. `--all` on herdr touches only sessions claude-remote spawned |
| `self-close` | From inside a session: deregister from [claude-keep](https://github.com/superbereza/claude-session-keeper), close itself |
| `refresh <session>` | Re-issue `/remote-control` → fresh URL, same chat |
| `heal [--dry-run]` | herdr: herdr resumes panes as a bare `claude --resume` (RC gets a derived name, permission mode/model reset); heal relaunches idle ones with the flags saved at spawn |
| `config [show\|path\|init\|edit]` | Settings |

`<session>` = chat title, its tail after `device/`, herdr workspace label / agent name / pane id, or the `cc—` tmux name. Ambiguous → error, never a guess.

## How spawn works

1. Resolves the folder (creates it if missing), builds the chat title (`rc_prefix` + name).
2. **Pre-trusts the folder** (`hasTrustDialogAccepted` in `~/.claude.json`, atomic) and pre-accepts bypass mode — no first-run dialog.
3. Starts claude with `--remote-control "<title>"` (named **at launch** — newer Claude auto-attaches RC with a derived name, a later `/remote-control` slash can't rename it) plus permission mode / model / effort.
   - tmux: `tmux new-session` + the command; ready = the TUI's mode line.
   - herdr: `herdr workspace create` + `herdr agent start <name> --kind claude -- <flags>`; flags saved to `~/.config/claude-remote/herdr-sessions.json` for `heal`.
4. Confirms Remote Control (state-file `bridgeSessionId` or the status bar), then sends the seed prompt (herdr: one paste — quotes/newlines safe).

## Why slash command, not server mode

`claude remote-control` (server mode) bundles all sessions inside a single process — when the server's OAuth token rotates (~24 h), the daemon dies and takes every session with it (see [#53635](https://github.com/anthropics/claude-code/issues/53635), [#53563](https://github.com/anthropics/claude-code/issues/53563)).

The slash-command approach this script uses keeps the conversation as a plain Claude session backed by `<uuid>.jsonl`. If Remote Control drops, run `claude-remote refresh <session>` to re-issue `/remote-control` inside the existing tmux pane — fresh URL, history preserved. If the `claude` process itself dies, you can `claude --resume <uuid> --dangerously-skip-permissions` and `/remote-control` again.

## Requirements

- `claude` ≥ 2.1.51 (Remote Control support), logged in with a Claude subscription
- `tmux` and/or `herdr` (≥ 0.9)
- `python3` (path resolution, settings, atomic JSON edits)

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the `~/.local/bin/claude-remote` symlink. Repo and `~/.claude.json` are not touched.

## OpenCode

This skill also supports [OpenCode](https://opencode.ai) — see [`.opencode/INSTALL.md`](.opencode/INSTALL.md).
