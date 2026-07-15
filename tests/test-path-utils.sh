#!/usr/bin/env bash
# Mirrors QuotaCommon.js path helpers (B009/B010) for CI without QML.
set -euo pipefail

python3 - <<'PY'
def expand_user_path(path):
    if not path:
        return ""
    p = str(path).strip()
    if p == "~":
        return "$HOME"
    if p.startswith("~/"):
        p = "$HOME/" + p[2:]
    if p.startswith("${HOME}"):
        p = "$HOME" + p[7:]
    return p.rstrip("/")

def path_compare_key(path):
    p = expand_user_path(path)
    if not p:
        return ""
    if p.startswith("$HOME/"):
        return p[6:]
    if p == "$HOME":
        return ""
    if p.startswith("/home/") or p.startswith("/Users/"):
        parts = p.split("/")
        if len(parts) >= 4:
            return "/".join(parts[3:])
    return p

def strip_auth_suffix(s):
    for suf in ("/.credentials.json", "/auth.json", "/config.json"):
        if s.endswith(suf):
            return s[: -len(suf)]
    return s

def paths_equal(a, b):
    if not a or not b:
        return False
    if str(a) == str(b):
        return True
    ka, kb = path_compare_key(a), path_compare_key(b)
    if ka and kb and ka == kb:
        return True
    sa, sb = strip_auth_suffix(ka), strip_auth_suffix(kb)
    return bool(sa and sb and sa == sb)

def default_cred_path(provider, config_dir):
    d = str(config_dir or "").rstrip("/")
    if not d:
        return ""
    if d.endswith(".json") or ".credentials" in d:
        return d
    return {
        "claude": d + "/.credentials.json",
        "codex": d + "/auth.json",
        "grok": d + "/auth.json",
        "opencode": d + "/auth.json",
        "zai": d + "/auth.json",
        "minimax": d + "/config.json",
        "kimi": d,
    }.get(provider, d)

def expand_to_absolute(path, home):
    if not path:
        return ""
    p = str(path).strip()
    if p == "~":
        return home or ""
    if p.startswith("~/"):
        return (home.rstrip("/") + "/" + p[2:]) if home else ""
    if p.startswith("${HOME}"):
        return (home.rstrip("/") + p[7:]) if home else ""
    if p.startswith("$HOME"):
        return (home.rstrip("/") + p[5:]) if home else ""
    return p

def shell_quote(path):
    return "'" + str(path).replace("'", "'\\''") + "'"

# B010 cases
assert paths_equal("~/.claude/.credentials.json", "/home/xertrov/.claude/.credentials.json")
assert paths_equal("$HOME/.codex/auth.json", "/home/me/.codex/auth.json")
assert paths_equal("/Users/me/.grok/auth.json", "~/.grok/auth.json")
assert not paths_equal("~/.claude/.credentials.json", "~/.codex/auth.json")

# B009 cases
assert default_cred_path("claude", "/home/me/.claude-custom") == "/home/me/.claude-custom/.credentials.json"
assert default_cred_path("codex", "/home/me/.codex-work") == "/home/me/.codex-work/auth.json"
assert default_cred_path("grok", "/home/me/.grok-3") == "/home/me/.grok-3/auth.json"
assert default_cred_path("minimax", "/home/me/.mmx") == "/home/me/.mmx/config.json"
assert default_cred_path("claude", "/home/me/.claude/.credentials.json") == "/home/me/.claude/.credentials.json"

# B006: expand then quote — injection becomes a literal path, not shell metachar
home = "/home/me"
evil = expand_to_absolute("$HOME/foo; rm -rf /", home)
assert evil == "/home/me/foo; rm -rf /"
q = shell_quote(evil)
assert q.startswith("'") and q.endswith("'")
assert "; rm" in q  # inside quotes — shell will not execute
assert expand_to_absolute("~/x", home) == "/home/me/x"
assert expand_to_absolute("~/x", "") == ""
assert expand_to_absolute("/abs/path", "") == "/abs/path"

print("path utils ok")
PY
