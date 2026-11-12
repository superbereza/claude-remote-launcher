# shellcheck shell=bash
# herdr backend for claude-remote — sourced by bin/claude-remote.  https://herdr.dev
# A session = a herdr workspace (label = title without rc_prefix) whose root pane runs one claude,
# started with `herdr agent start <name> --kind claude` so it has a stable agent NAME.
#
# What herdr gives natively and we just call: workspace create/close, agent start/prompt/read/wait,
# auto-resume of every claude pane after a server restart.
# What we add on top: RC title + permission mode + model at launch, folder pre-trust, seed prompt,
# the from/reply header, the registry of our launch flags, and `heal` (herdr resumes panes with a
# bare `claude --resume <uuid>`, losing all flags — heal relaunches them with the saved ones).
# Backend contract: see lib/backend-tmux.sh.

_H() {
    local h; h=$(resolve_herdr) || die "herdr not found (set herdr_bin in $CONFIG_FILE)"
    "$h" "$@"
}
_hh() {
    local h; h=$(resolve_herdr) || die "herdr not found"
    HERDR_BIN="$h" python3 "$SCRIPT_ROOT/lib/herdr_helper.py" "$@"
}
_jget() {   # _jget <python-expr on d> — read JSON from stdin
    python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

herdr_spawn() {
    local abs_path="$1" title="$2" show_url="$3" start_prompt="$4"

    # Free agent name (= slug of the title tail). On collision number both agent and title.
    local base_name name final="$title" i=2
    base_name=$(_hh slug "$title"); name="$base_name"
    while _hh taken "$name"; do
        name="${base_name:0:29}-$i"; final="${title}-${i}"; ((i++))
    done
    local label="$final"
    [[ -n "$CFG_rc_prefix" && "$final" == "$CFG_rc_prefix"* ]] && label="${final#"$CFG_rc_prefix"}"

    local ws_json ws pane
    ws_json=$(_H workspace create --cwd "$abs_path" --label "$label" --no-focus) \
        || die "herdr workspace create failed"
    ws=$(printf '%s' "$ws_json" | _jget 'd["result"]["workspace"]["workspace_id"]')
    pane=$(printf '%s' "$ws_json" | _jget 'd["result"]["root_pane"]["pane_id"]')
    sleep 1   # let the pane's shell reach its prompt (agent start requires an idle shell)

    build_claude_args "$final"
    local out rc=0
    out=$(_H agent start "$name" --kind claude --pane "$pane" --timeout 60000 -- "${CLAUDE_ARGS[@]}" 2>&1) || rc=$?
    if (( rc != 0 )); then
        if printf '%s' "$out" | grep -q agent_not_ready; then
            echo "claude-remote: claude started but is BLOCKED on a startup dialog in $pane:" >&2
            _H agent read "$name" --source visible --lines 25 >&2 || true
            echo "answer it: herdr agent send-keys $name <keys>   (or close: claude-remote kill $name)" >&2
        else
            echo "claude-remote: herdr agent start failed: $out" >&2
            echo "is 'claude' on the interactive PATH of a herdr pane? (herdr runs its canonical 'claude')" >&2
            _H workspace close "$ws" >/dev/null 2>&1 || true
        fi
        exit 1
    fi

    # Save our launch flags (minus --resume) so `heal` can restore them after a herdr restart.
    local args_json
    args_json=$(python3 -c 'import json,sys; a=sys.argv[1:]
out=[]; skip=False
for x in a:
    if skip: skip=False; continue
    if x=="--resume": skip=True; continue
    out.append(x)
print(json.dumps(out))' "${CLAUDE_ARGS[@]}")
    _hh reg-put "$name" "$(python3 -c 'import json,sys; print(json.dumps({"title":sys.argv[1],"cwd":sys.argv[2],"workspace":sys.argv[3],"pane":sys.argv[4],"args":json.loads(sys.argv[5])}, ensure_ascii=False))' \
        "$final" "$abs_path" "$ws" "$pane" "$args_json")"

    # Confirm Remote Control via the authoritative state file (bridgeSessionId), grab the URL.
    local rc_active=0 url="" screen iters
    iters=$(awk -v t="$URL_TIMEOUT_S" -v s="$POLL_INTERVAL_S" 'BEGIN{print int(t/s)}')
    for _ in $(seq 1 "$iters"); do
        (( rc_active )) || { _hh bridge "$pane" && rc_active=1; }
        if [[ -z "$url" ]]; then
            screen=$(_H agent read "$name" --source recent-unwrapped --lines 60 2>/dev/null || true)
            url=$(printf '%s' "$screen" | grep -oE "$URL_RE" | tail -1 || true)
        fi
        if (( rc_active )) && { (( !show_url )) || [[ -n "$url" ]]; }; then break; fi
        sleep "$POLL_INTERVAL_S"
    done

    # Seed: herdr delivers the text as one bracketed paste + Enter — any quotes/newlines are safe.
    local prompt_sent=0
    if [[ -n "$start_prompt" ]]; then
        _H agent prompt "$name" "$start_prompt" >/dev/null && prompt_sent=1
    fi

    printf 'SESSION: %s\n' "$final"
    printf 'BACKEND: herdr (agent %s, pane %s, workspace %s)\n' "$name" "$pane" "$ws"
    if (( show_url )); then
        if [[ -n "$url" ]]; then printf 'URL:     %s\n' "$url"
        elif (( rc_active )); then printf 'URL:     <RC active; link not captured — run: claude-remote refresh %q>\n' "$name"
        else printf 'URL:     <remote-control did not come up within %ss>\n' "$URL_TIMEOUT_S"; fi
    else
        if (( rc_active )); then printf 'STATUS:  remote-control active\n'
        else printf 'STATUS:  remote-control did NOT activate within %ss — check: herdr agent read %s\n' "$URL_TIMEOUT_S" "$name"; fi
    fi
    printf 'ATTACH:  herdr agent attach %s\n' "$name"
    (( prompt_sent )) && printf 'PROMPT:  sent (%d chars)\n' "${#start_prompt}"
    (( rc_active )) || exit 1
}

herdr_ls() { _hh ls; }

# → prints "<agent-or-pane>" (the id the other herdr_* functions take).
herdr_resolve() {
    local out rc=0
    out=$(_hh resolve "$1") || rc=$?
    (( rc == 0 )) || { printf '%s\n' "$out"; return "$rc"; }
    printf '%s\n' "${out%%$'\t'*}"
}

herdr_whoami() { _hh whoami; }

herdr_send() {
    local target="$1" text="$2" from="${3:-}" out rc=0
    out=$(_H agent prompt "$target" "$text" 2>&1) || rc=$?
    if (( rc != 0 )); then
        if printf '%s' "$out" | grep -q agent_blocked; then
            die "send: '$target' is waiting on a dialog (approval/question) — look first: herdr agent read $target"
        fi
        die "send: herdr agent prompt failed: $out"
    fi
    echo "sent to $target (${#text} chars${from:+, from $from})"
}

# Close the pane's whole workspace when it's the only pane (= a workspace we spawned), else just the
# pane. herdr stops claude with it; the PID sweep is a cheap safety net.
herdr_kill() {
    local target="$1" info pane ws name pids n
    info=$(_hh pane-of "$target") || die "kill: no live herdr agent '$target'"
    IFS=$'\t' read -r pane ws name <<< "$info"
    pids=$(_hh pids "$pane")
    n=$(_hh ws-panes "$ws")
    if [[ "$n" == 1 ]]; then _H workspace close "$ws" >/dev/null
    else _H pane close "$pane" >/dev/null; fi
    [[ -n "$name" ]] && _hh reg-del "$name"
    [[ -n "$pids" ]] && { sleep 1; _kill_claude_pids $pids; }
    echo "killed: ${name:-$pane}"
}

herdr_kill_all() {
    # Only sessions WE spawned (registry) — never other people's/tools' herdr agents.
    local reg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-remote/herdr-sessions.json" n any=0
    [[ -f "$reg" ]] || { echo "(no claude-remote herdr sessions to kill)"; return 0; }
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        if _hh pane-of "$n" >/dev/null; then herdr_kill "$n"; any=1
        else _hh reg-del "$n"; fi
    done < <(python3 -c 'import json,sys; [print(k) for k in json.load(open(sys.argv[1]))]' "$reg")
    (( any )) || echo "(no claude-remote herdr sessions running)"
}

herdr_refresh() {
    local target="$1" old_url url="" cand iters
    old_url=$(_H agent read "$target" --source recent-unwrapped --lines 200 2>/dev/null | grep -oE "$URL_RE" | tail -1 || true)
    _H agent prompt "$target" "/remote-control" >/dev/null || die "refresh: cannot prompt $target"
    iters=$(awk -v t="$URL_TIMEOUT_S" -v s="$POLL_INTERVAL_S" 'BEGIN{print int(t/s)}')
    for _ in $(seq 1 "$iters"); do
        cand=$(_H agent read "$target" --source recent-unwrapped --lines 200 2>/dev/null | grep -oE "$URL_RE" | tail -1 || true)
        [[ -n "$cand" && "$cand" != "$old_url" ]] && { url="$cand"; break; }
        sleep "$POLL_INTERVAL_S"
    done
    printf 'SESSION: %s\n' "$target"
    if [[ -n "$url" ]]; then printf 'URL:     %s\n' "$url"
    else printf 'URL:     <no new URL within %ss — old still: %s>\n' "$URL_TIMEOUT_S" "${old_url:-none}"; fi
    [[ -n "$url" ]] || exit 1
}

herdr_self_close() {
    local pane="${HERDR_PANE_ID:?}" info ws name
    info=$(_hh pane-of "$pane") || info="$pane	${HERDR_WORKSPACE_ID:-}	"
    IFS=$'\t' read -r pane ws name <<< "$info"
    [[ -n "$name" ]] && _hh reg-del "$name"
    echo "self-close: closing herdr ${ws:+workspace $ws / }pane $pane …"
    # Closing our own pane ends this process too — nothing after this line is guaranteed to run.
    if [[ -n "$ws" && "$(_hh ws-panes "$ws")" == 1 ]]; then _H workspace close "$ws" >/dev/null
    else _H pane close "$pane" >/dev/null; fi
}

# heal — after a herdr server restart every claude pane comes back as a bare `claude --resume <uuid>`
# (RC auto-attaches under a DERIVED name; permission mode / model fall back to defaults). For each
# registry session in that state AND idle, exit claude and relaunch it with the saved flags + resume.
herdr_heal() {
    local dry=0; [[ "${1:-}" == "--dry-run" ]] && dry=1
    local plan; plan=$(_hh heal-plan)
    [[ -z "$plan" ]] && { echo "heal: all claude-remote herdr sessions run with their launch flags — nothing to do"; return 0; }
    local name pane uuid status ent title
    while IFS=$'\t' read -r name pane uuid status; do
        [[ -n "$name" ]] || continue
        ent=$(_hh reg-get "$name"); title=$(printf '%s' "$ent" | _jget 'd["title"]')
        if [[ "$status" != idle && "$status" != done ]]; then
            echo "heal: skip $name ($title) — status '$status', not idle; retry later"; continue
        fi
        [[ -n "$uuid" ]] || { echo "heal: skip $name — herdr has no session uuid for it"; continue; }
        if (( dry )); then echo "heal: would relaunch $name ($title) --resume $uuid"; continue; fi
        echo "heal: relaunching $name ($title) …"
        _H agent prompt "$name" "/exit" >/dev/null 2>&1 || true
        local gone=0
        for _ in $(seq 1 60); do
            [[ -z "$(_hh pids "$pane")" ]] && { gone=1; break; }
            sleep 0.5
        done
        (( gone )) || { echo "heal: $name did not exit within 30s — left as is" >&2; continue; }
        sleep 1
        local -a args=()
        while IFS= read -r a; do args+=("$a"); done < <(printf '%s' "$ent" | _jget '"\n".join(d["args"])')
        if _H agent start "$name" --kind claude --pane "$pane" --timeout 60000 -- "${args[@]}" --resume "$uuid" >/dev/null 2>&1; then
            echo "heal: $name back with its flags ($title)"
        else
            echo "heal: $name relaunch did not report ready — check: herdr agent read $pane" >&2
        fi
    done <<< "$plan"
}
