# shellcheck shell=bash
# tmux backend for claude-remote — sourced by bin/claude-remote.
# A session = a detached tmux session named "cc—<chat title>" running one interactive claude.
#
# Backend contract (every lib/backend-*.sh implements these):
#   <b>_spawn ABS_PATH TITLE SHOW_URL PROMPT   start a new RC session
#   <b>_ls                                     print running sessions
#   <b>_resolve QUERY                          print the backend id; rc 1 = none, rc 2 = ambiguous
#   <b>_send ID TEXT FROM                      type TEXT into the session and submit it
#   <b>_kill ID  /  <b>_kill_all               close (and make sure claude is gone)
#   <b>_refresh ID                             re-issue /remote-control, print the new URL
#   <b>_self_close                             close the session this process runs in
#   <b>_whoami                                 chat title of the session this process runs in

# _tmux_bridge_up <tmux_name> <abs_cwd> — is Remote Control REGISTERED for this session?
# Claude writes ~/.claude/sessions/<pid>.json per process; it gains `bridgeSessionId` once RC is up.
# Matched by cwd (unique), else via the pane's process tree. Best-effort (rc 1 when unsure).
_tmux_bridge_up() {
    python3 - "$1" "$2" <<'PY'
import glob, json, os, subprocess, sys
tmux_name, want = sys.argv[1], sys.argv[2]
rp = os.path.realpath(want)
states = []
for f in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try: states.append(json.load(open(f)))
    except Exception: pass
by_cwd = [d for d in states if d.get("cwd") and os.path.realpath(d["cwd"]) == rp]
if len(by_cwd) == 1:
    sys.exit(0 if by_cwd[0].get("bridgeSessionId") else 1)
try:
    pane_pid = int(subprocess.run(["tmux", "list-panes", "-t", tmux_name, "-F", "#{pane_pid}"],
                                  capture_output=True, text=True).stdout.split()[0])
except Exception:
    pane_pid = 0
if pane_pid:
    children = {}
    for s in glob.glob("/proc/[0-9]*/stat"):
        try:
            txt = open(s).read(); pid = int(os.path.basename(os.path.dirname(s)))
            children.setdefault(int(txt.rsplit(") ", 1)[1].split()[1]), []).append(pid)
        except Exception: continue
    tree, stack = set(), [pane_pid]
    while stack:
        p = stack.pop()
        if p in tree: continue
        tree.add(p); stack += children.get(p, [])
    for d in states:
        if d.get("pid") in tree:
            sys.exit(0 if d.get("bridgeSessionId") else 1)
sys.exit(1)
PY
}

# _tmux_claude_pids <tmux_name> — PIDs of `claude` inside the session's pane trees. Capture BEFORE
# kill-session: claude survives it and orphans onto init (RAM/swap stay pinned).
# (/proc walk: Linux only; on macOS falls back to pgrep -P per level.)
_tmux_claude_pids() {
    python3 - "$1" <<'PY'
import os, subprocess, sys
try:
    roots = [int(x) for x in subprocess.run(["tmux", "list-panes", "-t", sys.argv[1], "-F", "#{pane_pid}"],
                                            capture_output=True, text=True).stdout.split()]
except Exception:
    roots = []
if not roots: sys.exit(0)
def kids(p):
    try:
        return [int(x) for x in subprocess.run(["pgrep", "-P", str(p)], capture_output=True, text=True).stdout.split()]
    except Exception:
        return []
tree, stack = set(), list(roots)
while stack:
    p = stack.pop()
    if p in tree: continue
    tree.add(p); stack += kids(p)
for p in sorted(tree):
    try:
        comm = subprocess.run(["ps", "-o", "comm=", "-p", str(p)], capture_output=True, text=True).stdout.strip()
        if os.path.basename(comm) == "claude": print(p)
    except Exception: pass
PY
}

tmux_spawn() {
    local abs_path="$1" title="$2" show_url="$3" start_prompt="$4"
    command -v tmux >/dev/null || die "tmux not found"
    local CLAUDE_BIN
    CLAUDE_BIN=$(resolve_claude) || die "claude not found (checked config claude_bin, PATH, ~/.npm-global/bin, ~/.local/bin, ~/.claude/local)"

    # Free name: EXACT match (tmux -t matches prefixes). On collision number BOTH tmux and title.
    local final="$title" i=2
    while tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qxF -- "cc${EM}${final}"; do
        final="${title}-${i}"; ((i++))
    done
    local tmux_name="cc${EM}${final}"

    build_claude_args "$final"
    local claude_cmd; claude_cmd=$(printf '%q ' "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}")

    tmux new-session -d -s "$tmux_name" -c "$abs_path"
    tmux send-keys -t "$tmux_name" "$claude_cmd" Enter

    # Ready = the TUI's mode line is drawn (any permission mode).
    local ready=0 pane
    for _ in $(seq 1 80); do
        pane=$(tmux capture-pane -p -J -t "$tmux_name" -S -200 2>/dev/null || true)
        if printf '%s' "$pane" | grep -qE 'bypass permissions on|auto mode on|accept edits on|plan mode on|\? for shortcuts'; then
            ready=1; break
        fi
        sleep 0.5
    done
    (( ready )) || { echo "claude-remote: claude TUI didn't reach ready state in 40s — check 'tmux attach -t $tmux_name'" >&2; exit 1; }

    local url="" rc_active=0 confirmed_rc=0 iters
    iters=$(awk -v t="$URL_TIMEOUT_S" -v s="$POLL_INTERVAL_S" 'BEGIN{print int(t/s)}')
    for _ in $(seq 1 "$iters"); do
        pane=$(tmux capture-pane -p -J -t "$tmux_name" -S -200 2>/dev/null || true)
        if (( !confirmed_rc )) && printf '%s' "$pane" | grep -q 'Enable Remote Control'; then
            tmux send-keys -t "$tmux_name" Enter; confirmed_rc=1; sleep 0.5; continue
        fi
        printf '%s' "$pane" | grep -qiE 'Remote Control active|remote-control is active' && rc_active=1
        (( rc_active )) || { _tmux_bridge_up "$tmux_name" "$abs_path" && rc_active=1; }
        [[ -z "$url" ]] && url=$(printf '%s' "$pane" | grep -oE "$URL_RE" | tail -1 || true)
        if (( rc_active )) && { (( !show_url )) || [[ -n "$url" ]]; }; then break; fi
        sleep "$POLL_INTERVAL_S"
    done

    local prompt_sent=0
    if [[ -n "$start_prompt" ]] && (( rc_active )); then
        tmux send-keys -t "$tmux_name" -l -- "$start_prompt"
        sleep 0.4
        tmux send-keys -t "$tmux_name" Enter
        prompt_sent=1
    fi

    printf 'SESSION: %s\n' "$final"
    printf 'BACKEND: tmux (%s)\n' "$tmux_name"
    if (( show_url )); then
        if [[ -n "$url" ]]; then printf 'URL:     %s\n' "$url"
        elif (( rc_active )); then printf 'URL:     <RC active; link not captured — run: claude-remote refresh %q>\n' "$final"
        else printf 'URL:     <remote-control did not come up within %ss — check pane>\n' "$URL_TIMEOUT_S"; fi
    else
        if (( rc_active )); then printf 'STATUS:  remote-control active\n'
        else printf 'STATUS:  remote-control did NOT activate within %ss — check pane\n' "$URL_TIMEOUT_S"; fi
    fi
    printf "ATTACH:  tmux attach -t '%s'\n" "$tmux_name"
    (( prompt_sent )) && printf 'PROMPT:  sent (%d chars)\n' "${#start_prompt}"
    if (( !rc_active )); then
        echo "claude-remote: --- last 30 lines of pane '$tmux_name' ---" >&2
        tmux capture-pane -p -J -t "$tmux_name" -S -30 2>/dev/null >&2 || true
        exit 1
    fi
}

tmux_ls() {
    local rows
    rows=$(tmux list-sessions -F '#{session_name}|#{session_path}' 2>/dev/null | grep "^cc${EM}" || true)
    [[ -z "$rows" ]] && { echo "(no cc— sessions running)"; return 0; }
    printf '%-50s  %s\n' "SESSION" "PATH"
    printf '%s\n' "$rows" | awk -F'|' '{ sub(/^cc—/, "", $1); printf "%-50s  %s\n", $1, $2 }'
}

# Accepts the full tmux name, the chat title (no cc—), or a bare tail after "device/".
tmux_resolve() {
    local q="$1" names n
    local -a hits=()
    names=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^cc${EM}" || true)
    [[ -n "$names" ]] || { echo "no cc— sessions running"; return 1; }
    while IFS= read -r n; do [[ "$n" == "$q" ]] && { printf '%s\n' "$n"; return 0; }; done <<< "$names"
    while IFS= read -r n; do [[ "$n" == "cc${EM}$q" ]] && { printf '%s\n' "$n"; return 0; }; done <<< "$names"
    while IFS= read -r n; do
        [[ "$n" == *"/$q" || "${n#cc${EM}}" == "$q" ]] && hits+=("$n")
    done <<< "$names"
    if (( ${#hits[@]} == 1 )); then printf '%s\n' "${hits[0]}"; return 0; fi
    if (( ${#hits[@]} > 1 )); then
        echo "ambiguous session '$q' — matches:"; printf '  %s\n' "${hits[@]}"; echo "be more specific."
        return 2
    fi
    echo "no such tmux session: $q"
    return 1
}

tmux_send() {
    local name="$1" text="$2" from="${3:-}" pane
    pane=$(tmux list-panes -a -F "#{session_name}"$'\t'"#{pane_id}" 2>/dev/null \
             | awk -F'\t' -v s="$name" '$1==s{print $2; exit}')
    [[ -n "$pane" ]] || die "send: no pane for $name"
    if tmux capture-pane -p -J -t "$pane" -S -3 2>/dev/null | grep -q 'esc to interrupt'; then
        echo "note: '${name#cc${EM}}' is busy — the message will queue until it's idle" >&2
    fi
    tmux send-keys -t "$pane" -l -- "$text"
    sleep 0.4
    tmux send-keys -t "$pane" Enter
    echo "sent to ${name#cc${EM}} (${#text} chars${from:+, from $from})"
}

tmux_kill() {
    local name="$1" pids
    pids=$(_tmux_claude_pids "$name")
    tmux kill-session -t "=$name" && echo "killed: ${name#cc${EM}}"
    [[ -n "$pids" ]] && _kill_claude_pids $pids
    return 0
}

tmux_kill_all() {
    local names n
    names=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^cc${EM}" || true)
    [[ -z "$names" ]] && { echo "(no cc— tmux sessions to kill)"; return 0; }
    while IFS= read -r n; do tmux_kill "$n"; done <<< "$names"
}

tmux_refresh() {
    local name="$1" old_url url="" pane cand iters
    old_url=$(tmux capture-pane -p -J -t "$name" -S -300 | grep -oE "$URL_RE" | tail -1 || true)
    tmux send-keys -t "$name" '/remote-control' Enter
    iters=$(awk -v t="$URL_TIMEOUT_S" -v s="$POLL_INTERVAL_S" 'BEGIN{print int(t/s)}')
    for _ in $(seq 1 "$iters"); do
        pane=$(tmux capture-pane -p -J -t "$name" -S -300 2>/dev/null || true)
        cand=$(printf '%s' "$pane" | grep -oE "$URL_RE" | tail -1 || true)
        [[ -n "$cand" && "$cand" != "$old_url" ]] && { url="$cand"; break; }
        sleep "$POLL_INTERVAL_S"
    done
    printf 'SESSION: %s\n' "${name#cc${EM}}"
    if [[ -n "$url" ]]; then printf 'URL:     %s\n' "$url"
    else printf 'URL:     <no new URL within %ss — old still: %s>\n' "$URL_TIMEOUT_S" "${old_url:-none}"; fi
    [[ -n "$url" ]] || exit 1
}

tmux_whoami() {
    local s; s=$(tmux display-message -p '#{session_name}' 2>/dev/null) || return 1
    printf '%s\n' "${s#cc${EM}}"
}

tmux_self_close() {
    local self pids
    self=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    [[ -n "$self" ]] || die "self-close: not inside a tmux session"
    echo "self-close: killing tmux session '$self' …"
    pids=$(_tmux_claude_pids "$self")     # capture BEFORE dropping tmux
    tmux kill-session -t "=$self"
    [[ -n "$pids" ]] && _kill_claude_pids $pids
    return 0
}
