---
name: claude-remote
description: Create a NEW Claude Code chat/session in any project folder (existing or brand-new) without leaving the current one — use for "create another chat with Claude", "spin up / start a new session", "open a new chat in <folder>", hand a task off to a fresh session, seed a new project, or run a parallel session in another repo. The new chat opens automatically as a Remote Control conversation on the user's device (phone / claude.ai/code), drivable from anywhere; pass --url to also print the link, or --prompt "<text>" to seed the new chat with a starting task. Runs in a detached tmux pane.
---

# claude-remote

Use `claude-remote` to spin up a fresh Claude Code session in any folder. The remote chat shows up automatically on the user's device, so by default the command just returns a **status** (no link). Pass `--url` only when the user explicitly wants the `claude.ai/code` link.

> **Invoking `claude-remote`:** call `claude-remote` directly. It's a self-contained bash script — no setup step.

> **You rarely need the URL.** Newer Claude Code versions **auto-attach Remote Control** — a spawned
> session appears on the user's device (phone / `claude.ai/code`) on its own, listed by its chat title.
> So the default (status only, no link) is almost always right: just tell the user the session is up
> and its name. Only pass `--url` when the user explicitly asks for a clickable link.

## Subcommands

| Command | Action |
|---------|--------|
| `claude-remote <path> [name] [--url] [--prompt <text>] [--resume <uuid>] [--model <m>] [--effort <e>]` | Spawn a session (default action; equivalent to `spawn`) |
| `claude-remote spawn <path> [name] [--url] [--prompt <text>] [--resume <uuid>] [--model <m>] [--effort <e>]` | Same as above, explicit |
| `claude-remote ls` | List running `cc—` tmux sessions with their cwd |
| `claude-remote send [--raw] <session> <text…>` | Send a message into an **existing** session's pane and submit it (the "talk to a session that's already running" op — `spawn --prompt` seeds a *new* chat, this drives a live one). Prefixes a **`[from <this session> — to reply: claude-remote send '<this session>' "…"]`** header so the receiver knows who's asking and how to answer back; `--raw` sends verbatim (no header). If the target is mid-generation the message just queues. |
| `claude-remote kill <session>` | Kill one tmux session |
| `claude-remote kill --all` | Kill all `cc—` tmux sessions |
| `claude-remote self-close` | Run **from inside** a session to end itself: deregister from `claude-keep` (if that skill is installed and the session is tracked), then kill its own tmux session. See note below. |
| `claude-remote refresh <session>` | Re-issue `/remote-control` to get a fresh URL after token rotation kills the old one |

## Quick Examples

```bash
# Launch in an existing project — chat title defaults to the folder name ("myproject")
claude-remote ~/dev/myproject

# Launch in a NEW folder (created and pre-trusted automatically)
claude-remote ~/dev/scratch-experiment

# Custom session name (becomes the remote-control chat title, verbatim)
claude-remote ~/dev/myproject debug-auth

# Full custom title, including a "device/" prefix if you use that convention
claude-remote ~/dev/ai-auth-lib "mac-mini/ai-auth-lib"

# Also print the claude.ai/code URL
claude-remote ~/dev/myproject --url

# List, kill one, kill all
claude-remote ls
claude-remote kill 'cc—myproject'
claude-remote kill --all
```

## Arguments

| Arg | Description |
|-----|-------------|
| `<path>` | Folder to run Claude in. Created with `mkdir -p` if missing. |
| `[name]` | Session name = remote-control **chat title**, used verbatim. Default: the folder name. Nothing is prepended automatically — if you use a `device/` prefix convention (e.g. `mac-mini/`), pass the full title yourself: `claude-remote ~/dev/ai-auth-lib "mac-mini/ai-auth-lib"`. **Collisions:** if a session with the exact same name is already running, the new one is numbered (`name-2`, `name-3`, …) on **both** the tmux session and the chat title, so the two are distinguishable. A name that is merely a *prefix* of an existing session (e.g. `dev` vs a running `dev-helper`) is **not** a collision and is created as-is. |

## Flags

| Flag | Effect |
|------|--------|
| `--url`, `-u` | Also print the `claude.ai/code` URL. **Default: status only** (no link). |
| `--prompt <text>`, `-p <text>` | **Seed the new chat.** Once Remote Control is up, the text is typed into the pane and submitted, so the fresh session immediately starts working on it. Great for "create a chat in X and have it do Y" in one call. |
| `--resume <uuid>`, `-r <uuid>` | Resume an existing session by UUID in the new tmux pane (instead of starting a fresh conversation). The session must exist in `~/.claude/projects/<cwd>/`. |
| `--model <m>`, `-m <m>` | Launch the session on a specific model — an alias (`opus`, `sonnet`, `fable`) or a full id (`claude-opus-4-8`). Omit to use claude's own default. See **Choosing the model & effort** below. |
| `--effort <e>`, `-e <e>` | Launch with an effort level: `low`, `medium`, `high`, `xhigh`, `max`. Omit to use claude's own default. |

## Choosing the model & effort

**Before spawning a session, clarify which model (and effort) the user wants** — don't
silently inherit a default. Ask (or confirm) and pass `--model <alias>` / `--effort <level>`:

```bash
claude-remote ~/dev/trendwatcher "dev-serv-in/trendwatcher" --model opus --effort max
```

Why this matters:
- A model set via `/model` in any session is **saved as the default for new sessions**,
  so a fresh spawn silently inherits whatever was last picked — which may not be what the
  user wants here.
- That inherited default can be **unavailable** (e.g. Fable during a capacity outage),
  and the session then can't run until someone switches it — easy to miss on a remote
  session you're not watching.

So treat model and effort as parameters to confirm at creation, the same as the path
and name. If the user doesn't care, omit the flags (claude's own defaults) — but say
that's what you're doing. Both can also be changed later in-session with `/model` and
`/effort`, but setting them at launch via `--model` / `--effort` avoids the
inherited-default trap entirely.

```
SESSION: cc—myproject
STATUS:  remote-control active
ATTACH:  tmux attach -t 'cc—myproject'
```

With `--url` the `STATUS` line is replaced by:

```
URL:     https://claude.ai/code/...
```

Exit code is `1` **only if Remote Control didn't activate** within 45s. A missing `--url`
link while RC is active is **not** a failure — the success signal is Remote Control being up
(the "Remote Control active" status bar **or** a `bridgeSessionId` in the state file), not the
URL (which can appear late or scroll out of view).

## What it does

1. Resolves the absolute path; flags whether it's a new folder.
2. Creates the folder if missing.
3. **Pre-trusts the path** by writing `hasTrustDialogAccepted: true` into `~/.claude.json` atomically.
4. Starts a detached tmux session in the path.
5. Runs `claude --dangerously-skip-permissions` inside (interactive TUI).
6. Waits for `bypass permissions on` to show in the bottom bar (TUI ready). Trust dialog is skipped thanks to step 3.
7. Sends `/remote-control <name>` slash command to enable Remote Control (name defaults to the folder).
8. Confirms Remote Control came up — from **two** signals, whichever fires first: the `Remote Control active` status bar in the pane, **or** a `bridgeSessionId` in Claude's per-process state file `~/.claude/sessions/<pid>.json` (authoritative — matched to this session by cwd, else by the pane's process tree). This makes startup detection robust to a lagging/reworded status bar.
9. With `--prompt <text>`, types the starting prompt into the pane and submits it. Prints the status (or the URL with `--url`). Tmux session keeps running.

## Talking to a running session, and ending one (`send` / `self-close`)

- **`send [--raw] <session> <text…>`** drives a session that's **already up** — it types the text into
  that session's pane and submits it. (`spawn --prompt` seeds a *brand-new* chat; `send` is for a live
  one.) If the target is mid-generation the message simply queues.
  - **Sender header (default):** the message is prefixed with `[from <your session> — to reply:
    claude-remote send '<your session>' "<your answer>"]`, so the receiver knows **whose** question it
    is and exactly **how to answer back** — turning `send` into a two-way, session-to-session channel.
    The sender is this command's own tmux session (`$TMUX`). Pass **`--raw`** to omit the header (for
    injecting a plain command/prompt, not a session-to-session message).
- **`self-close`** lets a session end **itself** — run it from inside the session. It does two things,
  and they belong to **two different skills**, so it keeps them decoupled:
  1. **Deregister from the registry** — that's `claude-session-keeper`'s job, so `self-close`
     *delegates* to **`claude-keep rm`** (which is self-aware: no arg → removes the calling session).
     It's called only if `claude-keep` is on PATH (best-effort; no hard dependency, and `claude-remote`
     never touches the registry file itself).
  2. **Drop the tmux session** — that's `claude-remote`'s own job (`tmux kill-session`).
  Order matters: unregister **before** dying, so a self-heal timer doesn't just relaunch it. If the
  keeper skill isn't installed, `self-close` still works — it just skips step 1 and kills the session.

## Why slash, not `claude remote-control` server mode

- Conversation lives as a normal Claude session (`<uuid>.jsonl`). Always `--resume`-able.
- If Remote Control connection dies (token rotates after ~1 day, network drops), `claude-remote refresh <session>` re-issues `/remote-control` inside the existing tmux pane — fresh URL, same chat history.
- Server mode bundles sessions inside a single process: when the server dies, all its sessions die with it.

## When to Use

- You want a fresh Claude session in an existing folder without leaving your current one.
- You want to spin up a brand-new project folder and get a session in it.
- You're driving Claude from a phone/browser and want to launch sessions remotely.

## Reporting back to the user

The remote chat appears automatically on the user's device, so **by default you don't need to share a link** — just confirm the session is up and give the chat name and tmux session, e.g.:

> Session `mac-mini/myproject` is up. tmux: `cc—myproject`

Only when the user explicitly asks for the URL, re-run with `--url`, parse the `URL: <...>` line, and present it as a **Markdown hyperlink** (clickable), not raw text:

> Session ready: [Open in browser](https://claude.ai/code?environment=env_xxx)
> tmux: `cc—myproject`

Always include the tmux session name so the user can `kill` it later.

## Notes

- Requires `claude` v2.1.51+ and a logged-in claude.ai subscription (Pro/Max/Team/Enterprise).
- The tmux session persists after the script exits — attach with `tmux attach -t <session>`.
- Em-dash (`—`) separates `cc—` prefix from the name in the tmux session name. Quote it when passing to `tmux` or `claude-remote kill`.
- The script writes `hasTrustDialogAccepted: true` to `~/.claude.json` for the path; trust is left in place after sessions are killed.
- The script also writes `bypassPermissionsModeAccepted: true` to `~/.claude/settings.json` so the first-run bypass-permissions confirmation dialog doesn't block startup. Idempotent — leaves other settings untouched.
- The first `/remote-control` call in a session also pops a one-time "Enable Remote Control" confirmation. The script auto-confirms it (default option) while polling for the URL.
- Disconnecting from claude.ai/code only drops the remote view — the local `claude` process keeps running until you `claude-remote kill` (or `tmux kill-session`).

## Spawning on a remote server (over SSH)

The skill is just bash + tmux + claude — it runs wherever you invoke it.
To spawn a session on a remote server:

1. Install `claude-remote` there once (`git clone … && bash scripts/install.sh`).
2. Make sure `claude` is installed and logged in on that server (`~/.claude/.credentials.json` must exist).
3. From your local machine, invoke through SSH:

```bash
ssh <alias> "bash -lc 'claude-remote <path> [name] [--url]'"
```

`bash -lc` is important so that `~/.local/bin` (where `scripts/install.sh` puts the
script) is on `PATH` for the non-interactive SSH shell. Alternative: call
the script by its absolute path (e.g. `~/.local/bin/claude-remote`).

The on-disk session belongs to the remote machine — `tmux attach -t …`
also has to be done over SSH. The remote-control URL works from any
device though, so you can drive the session from anywhere afterwards.
