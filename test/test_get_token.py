#!/usr/bin/env python3
"""End-to-end test of tools/get_token.py against a fake TickTick OAuth + API server."""
import base64
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request

try:  # LuaJIT is what KOReader runs; plain Lua 5.1 is close enough when lupa has no LuaJIT build
    from lupa.luajit21 import LuaRuntime  # noqa: E402
except ImportError:
    from lupa.lua51 import LuaRuntime  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "tools", "get_token.py")
FAKE_PORT = 8799
seen = {}


class Fake(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        seen["token_form"] = urllib.parse.parse_qs(self.rfile.read(length).decode())
        seen["token_auth"] = self.headers.get("Authorization")
        self._json({"access_token": 'tok"en\\1', "token_type": "bearer", "expires_in": 15551999, "scope": "tasks:read tasks:write"})

    def do_GET(self):
        seen["api_auth"] = self.headers.get("Authorization")
        self._json([{"id": "p1", "name": "Work"}, {"id": "p2", "name": "Home"}])

    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def start_script(out, extra=()):
    cmd = [
        sys.executable, "-I", SCRIPT, "--client-id", "cid", "--client-secret", "sec", "--no-browser",
        "--auth-url", f"http://localhost:{FAKE_PORT}/oauth/authorize",
        "--token-url", f"http://localhost:{FAKE_PORT}/oauth/token",
        "--api-url", f"http://localhost:{FAKE_PORT}/open/v1",
        "--out", out, "--timeout", "20", *extra,
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    url = None
    for line in proc.stdout:
        if line.strip().startswith("http://localhost"):
            url = line.strip()
            break
    assert url, "script never printed the login URL"
    return proc, urllib.parse.parse_qs(urllib.parse.urlparse(url).query)


def hit_callback(query):
    for _ in range(50):
        try:
            with urllib.request.urlopen("http://localhost:8765/callback?" + urllib.parse.urlencode(query), timeout=5) as r:
                return r.read().decode()
        except OSError:
            time.sleep(0.1)
    raise AssertionError("callback server never came up")


def main():
    server = http.server.HTTPServer(("127.0.0.1", FAKE_PORT), Fake)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    out = os.path.join(tempfile.mkdtemp(), "ticktick.lua")
    failures = 0

    def check(name, cond):
        nonlocal failures
        if not cond:
            failures += 1
            print("FAIL:", name)

    # Happy path
    proc, q = start_script(out, ["--utc-offset", "-5", "--inbox-id", "inbox42"])
    check("login url has scope", q["scope"] == ["tasks:read tasks:write"])
    check("login url has redirect", q["redirect_uri"] == ["http://localhost:8765/callback"])
    check("login url has client id", q["client_id"] == ["cid"])
    page = hit_callback({"code": "the-code", "state": q["state"][0]})
    check("browser page says done", "Done" in page)
    output = proc.stdout.read()
    check("exit 0", proc.wait(timeout=20) == 0)
    check("lists projects", "Work" in output and "Home" in output)
    check("expiry note", "180 days" in output)
    basic = base64.b64decode(seen["token_auth"].split()[1]).decode()
    check("basic auth", basic == "cid:sec")
    check("code sent", seen["token_form"]["code"] == ["the-code"])
    check("grant type", seen["token_form"]["grant_type"] == ["authorization_code"])
    check("redirect sent", seen["token_form"]["redirect_uri"] == ["http://localhost:8765/callback"])
    check("token used on api", seen["api_auth"] == 'Bearer tok"en\\1')

    lua = LuaRuntime(unpack_returned_tuples=True)
    data = lua.eval("function(p) return dofile(p) end")(out)
    check("lua loads file", data is not None)
    check("token round-trips through Lua quoting", data["access_token"] == 'tok"en\\1')
    check("offset", data["utc_offset_minutes"] == -300)
    check("inbox", data["extra_project_ids"][1] == "inbox42")
    check("file private", (os.stat(out).st_mode & 0o077) == 0)

    # Forged redirect (wrong state) must be refused
    out2 = out + ".2"
    proc, q = start_script(out2)
    hit_callback({"code": "evil", "state": "wrong"})
    proc.stdout.read()
    check("state mismatch exits non-zero", proc.wait(timeout=20) != 0)
    check("no file written on mismatch", not os.path.exists(out2))

    server.shutdown()
    print(f"get_token tests: {'OK' if not failures else str(failures) + ' failed'}")
    return failures


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
