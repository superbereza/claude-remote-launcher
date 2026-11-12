#!/usr/bin/env python3
"""claude-remote settings loader.

`config.py load <file>` prints shell assignments CFG_<key>=… and SRC_<key>=… (default|config|env)
for bash to eval. Precedence: built-in default < config file < CLAUDE_REMOTE_<KEY> env var.
(Command-line flags are applied on top by the bash side.)

The file is TOML. Python ≥3.11 parses it with tomllib; older Pythons (e.g. macOS system python)
fall back to a minimal `key = "value"` parser, which covers everything this config uses.
"""
import os
import re
import shlex
import sys

DEFAULTS = {
    "backend": "auto",              # auto | tmux | herdr
    "rc_prefix": "",                # prepended to the chat title, e.g. "dev-serv-in/"
    "permission_mode": "bypass",    # bypass | auto | acceptEdits | default | plan
    "model": "",                    # "" = claude's own default
    "effort": "",                   # "" = claude's own default
    "claude_bin": "",               # "" = auto-detect
    "herdr_bin": "",                # "" = auto-detect
    "message_header": "[from {from} — to reply: claude-remote send '{from}' \"<your answer>\"]",
}


def _mini_toml(text):
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$', line)
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if val.startswith('"'):
            m2 = re.match(r'^"((?:[^"\\]|\\.)*)"', val)
            val = m2.group(1).replace('\\"', '"').replace("\\\\", "\\") if m2 else val
        elif val.startswith("'"):
            m2 = re.match(r"^'([^']*)'", val)
            val = m2.group(1) if m2 else val
        else:
            val = val.split("#", 1)[0].strip()
        out[key] = val
    return out


def read_file(path):
    if not os.path.exists(path):
        return {}
    raw = open(path, "rb").read()
    try:
        import tomllib  # py3.11+
        return tomllib.loads(raw.decode())
    except ImportError:
        return _mini_toml(raw.decode())
    except Exception as e:  # malformed TOML — be loud, not silent
        sys.stderr.write(f"claude-remote: cannot parse {path}: {e}\n")
        sys.exit(1)


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "load":
        sys.exit("usage: config.py load <file>")
    data = read_file(sys.argv[2])
    for key in data:
        if key not in DEFAULTS:
            sys.stderr.write(f"claude-remote: warning: unknown config key '{key}' in {sys.argv[2]}\n")
    for key, default in DEFAULTS.items():
        env = os.environ.get("CLAUDE_REMOTE_" + key.upper())
        if env is not None:
            val, src = env, "env"
        elif key in data:
            val, src = data[key], "config"
        else:
            val, src = default, "default"
        print(f"CFG_{key}={shlex.quote(str(val))}")
        print(f"SRC_{key}={src}")


if __name__ == "__main__":
    main()
