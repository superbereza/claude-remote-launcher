---
name: herdr-migration
description: "Move a machine's Claude Code sessions from tmux (+ claude-remote / claude-keep) to herdr without losing a single conversation — install and run the herdr server as a service, hook Claude Code into it, stop the keeper's self-heal timer, move LIVE tmux sessions over warm (one transcript = one process), put paused ones on a shelf, restore Remote Control names after herdr restarts, verify, finalize, and roll back. Use when the user says \"переведи сессии на herdr\", \"мигрируй с tmux на herdr\", \"перенеси сессии в herdr\", \"move my sessions to herdr\", \"switch this machine from tmux to herdr\", or asks how to set up herdr for Claude sessions on a server or Mac. Day-to-day spawning/sending/closing afterwards is the claude-remote skill."
---

# herdr-migration — tmux → herdr, nothing lost

**herdr** ([herdr.dev](https://herdr.dev)) is a terminal runtime for coding agents: a background
server that keeps panes alive like tmux, but *recognizes* the agent in a pane (`idle` / `working` /
`blocked` / `done`), and after its own restart **resumes every Claude pane by itself**
(`claude --resume <uuid>`, the uuid comes from a Claude Code hook). It replaces tmux + the
claude-keep self-heal timer for Claude sessions. It does **not** replace tmux/systemd for ordinary
long-running services — leave those alone.

After the migration, sessions are still driven with `claude-remote` (its `herdr` backend), so
agents' habits don't change.

| before | after |
|---|---|
| `tmux new -s cc—X` + `claude` (`claude-remote spawn`) | herdr workspace + `herdr agent start` (`claude-remote spawn`, backend herdr) |
| `claude-keep restore` after reboot | built in: herdr resumes Claude panes itself; `claude-remote heal` restores our flags |
| `claude-keep pause` | close the pane — the transcript stays in `~/.claude/projects/…/<uuid>.jsonl`; back with `claude-remote spawn <cwd> <name> --resume <uuid>` |
| "who is waiting for me?" by hand | `herdr agent list` |

## Iron rules

1. **One transcript — one process.** Never run `claude --resume <uuid>` in tmux and in herdr at the
   same time. `/exit` the old one first, then start the new one.
2. **Don't kill a tmux session before herdr shows the same uuid** (`herdr agent get <pane>` →
   `agent_session.value`).
3. **Stop the keeper timer before starting** and turn it back on only to roll back.
4. **Memory:** every live `claude` holds its transcript in RAM. Check `free -h` before each next
   resume; under ~800 MB available — stop and ask the user.
5. Only this machine. Other machines (Mac, other servers) have their own servers.
6. Finish with a report: moved (title, uuid), shelved, skipped and why.

## 0. Preflight

```bash
export PATH="$HOME/.local/bin:$PATH"
tmux ls                                          # live cc— sessions = what moves warm
cat ~/.claude-keep/sessions.tsv 2>/dev/null      # keeper registry: name<TAB>uuid<TAB>cwd<TAB>effort<TAB>rc[<TAB>paused]
cp ~/.claude-keep/sessions.tsv ~/.claude-keep/sessions.tsv.bak-$(date +%F) 2>/dev/null
free -h
```

## 1. Install herdr and run the server as a service

Install the binary per [herdr.dev](https://herdr.dev) (single binary → `~/.local/bin/herdr`;
`herdr update` keeps it current). Then:

**Linux (systemd user unit, starts at boot without login):**
```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/herdr-server.service <<'EOF'
[Unit]
Description=herdr server (headless runtime for coding agents)
After=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/herdr server
Restart=always
RestartSec=5
Environment=PATH=%h/.local/bin:%h/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
Environment=LANG=en_US.UTF-8

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload && systemctl --user enable --now herdr-server
sudo loginctl enable-linger "$USER"     # ask the user first — survive logout/reboot
herdr status                             # server: running
```
(`PATH` must contain the directory with `claude` — herdr starts the canonical `claude` from a pane's PATH.)

**macOS:** run `herdr` (the app/TUI starts the server) or a launchd agent with `herdr server`.

**Hook Claude Code in** (lets herdr learn each pane's session uuid — required for auto-resume):
```bash
herdr integration install claude
herdr integration status                 # claude: current
```

**claude-remote on herdr:** `claude-remote config init` (then edit `rc_prefix`, `permission_mode`, …),
`claude-remote config show` → `effective backend: herdr`.

## 2. Stop the keeper's self-heal timer

Otherwise it relaunches in tmux what you are moving.
```bash
systemctl --user stop claude-keep-restore.timer      # stop, NOT disable — rollback is one `start`
systemctl --user is-active claude-keep-restore.timer # inactive
```

## 3. Move LIVE tmux sessions (warm)

For each live `cc—<title>` session:

```bash
T='cc—dev-serv-in/foo'                       # tmux name
CWD=$(tmux display-message -p -t "$T" '#{pane_current_path}')
# uuid: keeper registry row, or the newest transcript of that cwd:
#   ls -t ~/.claude/projects/$(echo "$CWD" | sed 's#[/.]#-#g')/*.jsonl | head -1   (file name = uuid)
UUID=<uuid>

tmux send-keys -t "$T" '/exit' Enter; sleep 5          # end claude in tmux first (rule 1)
claude-remote --backend herdr spawn "$CWD" "${T#cc—}" --resume "$UUID"   # same chat title, herdr
herdr agent get <agent-name>                            # agent_session.value == $UUID  (rule 2)
tmux kill-session -t "=$T"                              # only now
```
If the spawn reports **blocked** (a "Resume session?" / trust dialog): `herdr agent read <name>`,
answer with `herdr agent send-keys <name> down enter` (for "Resume session?" pick the full resume).
Use the **same chat title** so the conversation keeps its name on the phone.

## 4. Paused sessions → a shelf, not RAM

Paused keeper rows (`paused` column) were not running in tmux — keep them that way. Write a shelf
file (e.g. `~/dev/HERDR-SESSIONS.md`): `title | cwd | uuid | note`, newest row per name:
```bash
awk -F'\t' '!/^#/ && NF>=3 {print "| " $1 " | " $3 " | " $2 " |"}' ~/.claude-keep/sessions.tsv | sort -u
```
Bring one back on demand: `claude-remote spawn <cwd> <title> --resume <uuid>`.

## 5. Remote Control after herdr restarts

herdr resumes panes as a bare `claude --resume <uuid>`: RC re-attaches under a *derived* name, and
permission mode / model revert to defaults. Sessions started by `claude-remote` (incl. step 3) have
their flags saved, so after any herdr restart run:
```bash
claude-remote heal --dry-run     # what would be relaunched
claude-remote heal               # relaunch idle ones with their flags + --resume (busy ones: retry later)
```
Sessions started some other way show in `claude-remote ls` as `[workspace-label]`; to adopt one,
`/exit` it and re-spawn it with `claude-remote spawn <cwd> <title> --resume <uuid>`.

## 6. Verify "survives a restart"

```bash
herdr agent list                         # note pane → uuid
systemctl --user restart herdr-server    # simulates a reboot — ASK the user first: every live session restarts
sleep 30; herdr agent list               # same panes, agent=claude, same uuids
claude-remote heal
```
A pane that came back as an empty shell had no `agent_session` (hook missing) — check
`herdr integration status`, then re-spawn it from its uuid.

## 7. Finalize

- All needed sessions live in herdr and step 6 passed →
  `systemctl --user disable --now claude-keep-restore.timer`. Keep `~/.claude-keep/sessions.tsv`
  (uuid history).
- `tmux ls` shows no `cc—` sessions (other tmux sessions: don't touch).
- Optional: `backend = "herdr"` in `~/.config/claude-remote/config.toml` to pin it.

## Rollback (any step)

```bash
herdr agent list                                   # close the moved panes FIRST (rule 1):
claude-remote --backend herdr kill <name>          #   …for each one moved
systemctl --user start claude-keep-restore.timer   # within ≤5 min tmux sessions come back from the registry
```

## Cheat sheet (raw herdr)

```bash
herdr status                                  # server alive? versions
herdr workspace list | python3 -m json.tool
herdr agent list                              # every agent: name, pane, status, session uuid
herdr agent get|read|wait <name|pane> …       # inspect one
herdr agent send-keys <name> esc|enter|down|ctrl+c
herdr pane send-keys <pane> ctrl+c            # clear a stuck shell `quote>`
herdr pane process-info --pane <pane>         # argv of what runs in the pane
herdr --skill                                 # herdr's own full agent guide
```
Logs: `~/.config/herdr/herdr-server.log`, `journalctl --user -u herdr-server`.
