---
name: claude-remote
description: "Manage Claude Code Remote Control sessions — in herdr workspaces or detached tmux panes (pluggable backend, picked from a settings file). PRIMARY use — create a NEW chat/session in any project folder (existing or brand-new) without leaving the current one: \"create another chat with Claude\", \"spin up / start a new session\", \"open a new chat in <folder>\", \"подними сессию\", hand a task off to a fresh session, seed a new project, run a parallel session in another repo (--prompt / --prompt-file seeds a starting task; --url also prints the claude.ai/code link). ALSO use to DRIVE or CLOSE running sessions — send a message into a live session (\"message / tell the <X> session\", \"reply to that session\"), list them, and END one. When a session is asked to close ITSELF — \"close this session\", \"end / shut down this chat\", \"self-close\", \"закрой / заверши эту сессию\", \"заверши сам себя\" — run `claude-remote self-close` from inside it (deregisters from claude-keep, closes its own tmux session / herdr workspace AND its claude process); do NOT use the app-level \"end chat\" (leaves the process running). After a herdr server restart, `claude-remote heal` restores sessions' chat titles / permission mode / model. Settings (backend, chat-title prefix, permission mode, default model/effort, message header): `claude-remote config show`. To MOVE a machine's sessions from tmux to herdr use the herdr-migration skill."
---

# claude-remote

Spin up a fresh Claude Code session in any folder, talk to running ones, close them. Each session
is a **Remote Control** chat that appears on the user's device (phone / claude.ai/code) on its own,
so by default `spawn` just prints a **status** — pass `--url` only when the user asks for the link.

> **Invoking:** call `claude-remote` directly (self-contained bash + python3, no setup step).

## Backends

One CLI, the same verbs, different session runtimes underneath:

| backend | a session is | needs |
|---|---|---|
| `herdr` | a herdr workspace whose pane runs `claude`, started with `herdr agent start` → it has an agent **name** | `herdr` server running ([herdr.dev](https://herdr.dev)) |
| `tmux`  | a detached tmux session `cc—<chat title>` | `tmux` |

`backend = "auto"` (default): **herdr** if its server is running (or you are inside a herdr pane),
otherwise **tmux**. Commands that look up an existing session (`send`, `kill`, `refresh`, `ls`)
search **every** available backend in auto mode. Force one per call with `--backend tmux|herdr`.

## Settings

`claude-remote config show` prints every effective value and where it came from. File:
`~/.config/claude-remote/config.toml` (`claude-remote config init` writes the commented example).
Precedence: built-in default < file < `CLAUDE_REMOTE_<KEY>` env < command-line flag.

| key | built-in default | meaning |
|---|---|---|
| `backend` | `auto` | `auto` \| `tmux` \| `herdr` |
| `rc_prefix` | `""` | prepended to every chat title unless the name has a `/` — e.g. `dev-serv-in/` |
| `permission_mode` | `bypass` | `bypass` (= `--dangerously-skip-permissions`) \| `auto` \| `acceptEdits` \| `default` \| `plan` |
| `model`, `effort` | `""` | defaults for new sessions (`""` = claude's own) |
| `claude_bin`, `herdr_bin` | `""` | absolute paths if auto-detect guesses wrong |
| `message_header` | `[from {from} — to reply: claude-remote send '{from}' "<your answer>"]` | prefix of `send` messages |

## Subcommands

| Command | Action |
|---------|--------|
| `claude-remote spawn <path> [name] [flags]` | Spawn a session in `<path>`. **Spawning is explicit** — the `spawn` verb is required. |
| `claude-remote ls` | List running sessions of every available backend |
| `claude-remote send [--raw] <session> <text…>` | Send a message into an **existing** session and submit it, with a **from/reply header** (`--raw` omits it) |
| `claude-remote kill <session>` | Close one session — and make sure its claude process is gone |
| `claude-remote kill --all` | Close all *our* sessions: every `cc—` tmux session; on herdr only sessions claude-remote spawned (never other tools' agents) |
| `claude-remote self-close` | From **inside** a session: deregister from claude-keep, then close itself |
| `claude-remote refresh <session>` | Re-issue `/remote-control` for a fresh URL |
| `claude-remote heal [--dry-run]` | herdr only — relaunch sessions that herdr auto-resumed **without** our flags (see below) |
| `claude-remote config [show\|path\|init\|edit]` | Settings |

### Spawn flags

| Flag | Effect |
|------|--------|
| `--prompt <text>`, `-p` | **Seed the new chat** with a first message — the session starts working on it at once |
| `--prompt-file <file>` | Same, from a file — use it for long/multi-line seeds (any quotes, `$`, parens are safe) |
| `--resume <uuid>`, `-r` | Resume an existing conversation instead of a fresh one |
| `--model <m>`, `-m` / `--effort <e>`, `-e` | Model alias/id and effort (`low…max`); default from settings |
| `--permission-mode <pm>` | Override `permission_mode` for this session |
| `--url`, `-u` | Also print the `claude.ai/code` URL |
| `--backend <b>` | (any command) override the configured backend |

`[name]` = the chat title. Default: `rc_prefix` + folder name. A name containing `/` is used
verbatim (`"mac-mini/ai-auth-lib"`). **Collisions:** an exact duplicate is numbered (`name-2`) on
the chat title **and** the tmux name / herdr agent, so the two stay distinguishable.

## Examples

```bash
claude-remote spawn ~/dev/myproject                       # title = <rc_prefix>myproject
claude-remote spawn ~/dev/scratch-new "debug-auth" --model opus --effort high
claude-remote spawn ~/dev/repo --prompt-file /tmp/seed.txt  # long seed task from a file
claude-remote ls
claude-remote send debug-auth "check the failing test and report"
claude-remote kill debug-auth
```

Output:
```
SESSION: dev-serv-in/myproject
BACKEND: herdr (agent myproject, pane w4:p1, workspace w4)
STATUS:  remote-control active
ATTACH:  herdr agent attach myproject
```
Exit `1` only if Remote Control didn't come up in 45s (success = a `bridgeSessionId` in Claude's
state file `~/.claude/sessions/<pid>.json` or the "Remote Control active" bar — not the URL).

## Choosing the model & effort

**Before spawning, confirm which model (and effort) the user wants** — don't silently inherit one.
A model picked with `/model` in any session becomes the default for new sessions, and that default
can be unavailable (capacity outage) on a remote session nobody is watching. Pass `--model` /
`--effort`, or put the user's standing choice into the settings file. If the user doesn't care,
say you're using the defaults.

## Referring to sessions

`send` / `kill` / `refresh` take whatever you'd say out loud: the full chat title
(`dev-serv-in/fleetos-devops`), its tail after `device/` (`fleetos-devops`, matched whole), the
herdr workspace label, the herdr agent name or pane id (`w4:p1`), or the raw `cc—…` tmux name.
Ambiguous → error listing the matches (it never guesses).

## Talking to a running session — `send`

`send` types the text into a **live** session and submits it (`spawn --prompt` is for a *new* one).
By default it is prefixed with the `message_header` — `[from <your session> — to reply:
claude-remote send '<your session>' "<your answer>"]` — so the receiver knows whose question it is
and how to answer: a two-way session-to-session channel. (herdr has no built-in agent messaging —
`herdr agent prompt` only delivers text — so the header is ours.) `--raw` sends verbatim.
- tmux: a busy target just queues the message.
- herdr: delivered as one paste + Enter (quotes/newlines safe). A target **blocked on a dialog**
  (approval / question) is refused — look first: `herdr agent read <name>`.

## Ending a session — `self-close` / `kill`

`self-close` is **the** way for a session to end itself on request ("close this session",
"заверши себя"). Not the app's "end chat" — that leaves claude (hundreds of MB) running. It:
1. deregisters from `claude-keep` (if installed — `claude-keep rm`), **before** dying, so a
   self-heal timer doesn't relaunch it;
2. closes its own tmux session / herdr workspace;
3. makes sure the claude process is gone — tmux: claude ignores SIGHUP and would orphan with its
   RAM/swap pinned, so the PID is SIGTERM→SIGKILLed; herdr stops it itself (PID sweep as a net).

## herdr specifics

- **Startup:** the folder is pre-trusted, then `herdr agent start <name> --kind claude --pane <p>
  -- <flags>`; herdr returns once claude is ready. The `claude` herdr runs is the one on a pane's
  interactive `PATH`.
- **After a herdr server restart** herdr brings every claude pane back by itself — but as a bare
  `claude --resume <uuid>`: Remote Control re-attaches under a **derived** chat name and the
  permission mode / model fall back to defaults. claude-remote keeps each spawn's flags in
  `~/.config/claude-remote/herdr-sessions.json`; **`claude-remote heal`** exits such sessions
  (only when idle) and relaunches them with their flags + `--resume`. `--dry-run` shows the plan.
  Sessions it didn't spawn show in `ls` as `[workspace-label]` and are left alone.
- **Escape hatches** (raw herdr, when something is stuck):
  ```bash
  herdr agent list                                   # all agents + status (idle/working/blocked/done)
  herdr agent read <name|pane> --source recent-unwrapped --lines 80   # see the screen
  herdr agent send-keys <name|pane> down enter       # answer a startup dialog (trust / resume …)
  herdr pane send-keys <pane> ctrl+c                 # clear a stuck shell `quote>` in a pane
  herdr agent wait <name> --until done --timeout 600000   # wait for an answer
  herdr workspace close <ws>                         # last resort close
  ```
  A "Resume session?" dialog on a big `--resume`: pick the full resume (option 2).

## tmux specifics

- `tmux attach -t 'cc—<title>'` to look at a session; quote the em-dash name.
- Startup readiness = the TUI's mode line; the one-time "Enable Remote Control" prompt is
  auto-confirmed. Recovery after a reboot is `claude-session-keeper`'s job (tmux has no auto-resume).

## Reporting back to the user

Confirm the session is up and give its **chat title** (what they see on the phone), e.g.
> Session `dev-serv-in/myproject` is up (herdr agent `myproject`).

Only if they asked for the link: re-run with `--url` and present it as a Markdown link.

## Notes

- Requires `claude` v2.1.51+ (logged in to a claude.ai plan) and `python3`; tmux and/or herdr.
- Spawn writes `hasTrustDialogAccepted` for the folder into `~/.claude.json` and
  `bypassPermissionsModeAccepted` into `~/.claude/settings.json` (idempotent, other keys untouched).
- On another machine over SSH: `ssh <host> "bash -lc 'claude-remote spawn <path> [name]'"`
  (`bash -lc` puts `~/.local/bin` on PATH).
