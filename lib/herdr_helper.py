#!/usr/bin/env python3
"""JSON-side helpers for claude-remote's herdr backend (bash does the orchestration).

Env: HERDR_BIN = absolute path to herdr.
Registry: ~/.config/claude-remote/herdr-sessions.json — sessions WE spawned, keyed by herdr agent
name: {title, cwd, workspace, pane, args}. herdr itself only remembers the conversation uuid and
resumes panes with a bare `claude --resume <uuid>`; the registry keeps our launch flags so `heal`
can restore the RC title / permission mode / model after a herdr restart.

Subcommands (exit 0 = ok):
  slug TITLE               agent name for a chat title ([a-z][a-z0-9_-]{0,31})
  taken NAME               exit 0 if a live agent or a live registry entry already uses NAME
  ls                       table of live claude agents
  resolve QUERY            print "<agent-or-pane>\t<title>"; exit 1 none, 2 ambiguous
  whoami                   chat title (or agent name / pane) of $HERDR_PANE_ID
  pane-of TARGET           print "<pane_id>\t<workspace_id>\t<name>"
  pids PANE                claude PIDs running in PANE
  bridge PANE              exit 0 if PANE's claude has Remote Control registered
  ws-panes WS              number of panes in workspace WS
  reg-put NAME JSON | reg-del NAME | reg-get NAME
  heal-plan                "<name>\t<pane>\t<uuid>\t<status>" for registry sessions running WITHOUT our flags
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HERDR = os.environ.get("HERDR_BIN", "herdr")
REG = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
                   "claude-remote", "herdr-sessions.json")


def herdr(*args, check=True):
    p = subprocess.run([HERDR, *args], capture_output=True, text=True)
    if p.returncode != 0:
        if check:
            sys.stderr.write(p.stderr or p.stdout)
            sys.exit(3)
        return None
    try:
        return json.loads(p.stdout)["result"]
    except Exception:
        return None


def agents():
    r = herdr("agent", "list", check=False) or {}
    return [a for a in r.get("agents", []) if a.get("agent") == "claude"]


def process_info(pane):
    r = herdr("pane", "process-info", "--pane", pane, check=False) or {}
    return r.get("process_info", {})


def claude_argv(pane):
    for p in process_info(pane).get("foreground_processes", []):
        if os.path.basename(p.get("name", "")) == "claude" or (p.get("argv") or [""])[0].endswith("claude"):
            return p.get("argv", []), p.get("pid")
    return [], None


def title_from_argv(argv):
    for i, a in enumerate(argv):
        if a == "--remote-control" and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith("--remote-control="):
            return a.split("=", 1)[1]
    return ""


def reg_load():
    try:
        return json.load(open(REG))
    except Exception:
        return {}


def reg_save(d):
    os.makedirs(os.path.dirname(REG), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".herdr-sessions.", dir=os.path.dirname(REG))
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    os.replace(tmp, REG)


def slug(title):
    tail = title.rsplit("/", 1)[-1].lower()
    s = re.sub(r"[^a-z0-9_-]+", "-", tail).strip("-") or "claude"
    if not s[0].isalpha():
        s = "cr-" + s
    return s[:32].rstrip("-")


def ws_labels():
    r = herdr("workspace", "list", check=False) or {}
    return {w.get("workspace_id"): w.get("label", "") for w in r.get("workspaces", [])}


def live_rows():
    """[(name, pane, ws, status, title, cwd, uuid, label)] for live claude agents."""
    reg = reg_load()
    labels = ws_labels()
    by_pane = {v.get("pane"): (k, v) for k, v in reg.items()}
    rows = []
    for a in agents():
        pane = a.get("pane_id", "")
        argv, _ = claude_argv(pane)
        title = title_from_argv(argv)
        if not title:
            name = a.get("name") or ""
            if name in reg:
                title = reg[name].get("title", "")
            elif pane in by_pane:
                title = by_pane[pane][1].get("title", "")
        rows.append((a.get("name") or "", pane, a.get("workspace_id", ""), a.get("agent_status", ""),
                     title, a.get("cwd", ""), (a.get("agent_session") or {}).get("value", ""),
                     labels.get(a.get("workspace_id"), "")))
    return rows


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]

    if cmd == "slug":
        print(slug(args[0]))

    elif cmd == "taken":
        name = args[0]
        live = {a.get("name") for a in agents()}
        sys.exit(0 if name in live else 1)

    elif cmd == "ls":
        rows = live_rows()
        if not rows:
            print("(no claude agents running in herdr)")
            return
        print(f"{'SESSION (chat title, or [workspace])':<42}  {'AGENT':<16}  {'PANE':<7}  {'STATUS':<8}  PATH")
        for name, pane, ws, st, title, cwd, _, label in sorted(rows, key=lambda r: (r[4] or r[7] or r[1]).lower()):
            shown = title or (f"[{label}]" if label else "-")
            print(f"{shown:<42}  {(name or '-'):<16}  {pane:<7}  {st:<8}  {cwd}")
        print("(sessions without a chat title were auto-resumed by herdr — `claude-remote heal` restores ours)")

    elif cmd == "resolve":
        q = args[0]
        rows = live_rows()
        exact = [r for r in rows if q in (r[0], r[1]) or (r[4] and r[4] == q)]
        if not exact:
            exact = [r for r in rows if r[7] and r[7] == q]   # workspace label
        if len(exact) == 1:
            r = exact[0]
            print(f"{r[0] or r[1]}\t{r[4]}")
            return
        tail = [r for r in rows if r[4] and r[4].endswith("/" + q)]
        hits = exact or tail
        if len(hits) == 1:
            r = hits[0]
            print(f"{r[0] or r[1]}\t{r[4]}")
            return
        if len(hits) > 1:
            print(f"ambiguous session '{q}' — matches:")
            for r in hits:
                print(f"  {r[4] or '-'}  (agent {r[0] or '-'}, pane {r[1]})")
            print("be more specific (use the agent name or pane id).")
            sys.exit(2)
        print(f"no such herdr session: {q}")
        sys.exit(1)

    elif cmd == "whoami":
        me = os.environ.get("HERDR_PANE_ID", "")
        for name, pane, ws, st, title, cwd, _, label in live_rows():
            if pane == me:
                print(title or name or label or pane)
                return
        if me:
            print(me)
            return
        sys.exit(1)

    elif cmd == "pane-of":
        t = args[0]
        for a in agents():
            if t in (a.get("name"), a.get("pane_id")):
                print(f"{a.get('pane_id')}\t{a.get('workspace_id')}\t{a.get('name') or ''}")
                return
        sys.exit(1)

    elif cmd == "pids":
        info = process_info(args[0])
        pids = {p.get("pid") for p in info.get("foreground_processes", [])
                if os.path.basename(p.get("name", "")) == "claude"}
        for p in sorted(x for x in pids if x):
            print(p)

    elif cmd == "bridge":
        _, pid = claude_argv(args[0])
        if not pid:
            sys.exit(1)
        try:
            d = json.load(open(os.path.expanduser(f"~/.claude/sessions/{pid}.json")))
        except Exception:
            sys.exit(1)
        sys.exit(0 if d.get("bridgeSessionId") else 1)

    elif cmd == "ws-panes":
        r = herdr("workspace", "get", args[0], check=False) or {}
        print((r.get("workspace") or {}).get("pane_count", 0))

    elif cmd == "reg-put":
        d = reg_load()
        d[args[0]] = json.loads(args[1])
        reg_save(d)

    elif cmd == "reg-del":
        d = reg_load()
        if d.pop(args[0], None) is not None:
            reg_save(d)

    elif cmd == "reg-get":
        d = reg_load()
        if args[0] not in d:
            sys.exit(1)
        print(json.dumps(d[args[0]]))

    elif cmd == "heal-plan":
        reg = reg_load()
        live = {a.get("name"): a for a in agents()}
        for name, ent in reg.items():
            a = live.get(name)
            if not a:
                continue
            argv, _ = claude_argv(a.get("pane_id", ""))
            if "--remote-control" in argv or any(x.startswith("--remote-control=") for x in argv):
                continue  # still running with our flags
            uuid = (a.get("agent_session") or {}).get("value", "")
            print(f"{name}\t{a.get('pane_id')}\t{uuid}\t{a.get('agent_status')}")

    else:
        sys.exit(f"unknown helper command {cmd}")


if __name__ == "__main__":
    main()
