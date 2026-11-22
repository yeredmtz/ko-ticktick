#!/usr/bin/env python3
"""Get a TickTick access token and write the KOReader config file.

Run this on a computer (not the Kindle). It needs only the Python standard
library. It opens TickTick's login page, catches the redirect on localhost,
exchanges the code for an access token, checks the token works, and writes
`ticktick.lua`, which you copy to  koreader/settings/  on the Kindle.

Before the first run, register an app at https://developer.ticktick.com
(Manage Apps > New App) and set its OAuth redirect URL to exactly:

    http://localhost:8765/callback

Usage:
    python3 get_token.py --client-id ID --client-secret SECRET
    python3 get_token.py            # prompts for the id and secret

Options worth knowing:
    --utc-offset -5      fix the time zone used for "today" (hours from UTC)
    --inbox-id ID        add your Inbox list id (see README)
    --dida365            use the Chinese service (dida365.com) instead
    --out PATH           where to write the file (default: ./ticktick.lua)
"""

import argparse
import base64
import getpass
import http.server
import json
import secrets
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

SERVICES = {
    "ticktick": {
        "auth": "https://ticktick.com/oauth/authorize",
        "token": "https://ticktick.com/oauth/token",
        "api": "https://api.ticktick.com/open/v1",
    },
    "dida365": {
        "auth": "https://dida365.com/oauth/authorize",
        "token": "https://dida365.com/oauth/token",
        "api": "https://api.dida365.com/open/v1",
    },
}
SCOPE = "tasks:read tasks:write"
PORT = 8765
REDIRECT_URI = f"http://localhost:{PORT}/callback"


def lua_quote(value: str) -> str:
    """Quote a string as a Lua string literal."""
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )
    return f'"{escaped}"'


def render_settings(settings: dict) -> str:
    """Render a dict as a file KOReader's LuaSettings can load."""
    lines = ["-- TickTick plugin settings (created by get_token.py)", "return {"]
    for key, value in settings.items():
        if isinstance(value, bool):
            rendered = "true" if value else "false"
        elif isinstance(value, (int, float)):
            rendered = repr(value)
        elif isinstance(value, list):
            rendered = "{ " + ", ".join(lua_quote(str(v)) for v in value) + " }"
        else:
            rendered = lua_quote(str(value))
        lines.append(f'    ["{key}"] = {rendered},')
    lines.append("}")
    return "\n".join(lines) + "\n"


def wait_for_code(expected_state: str, timeout: int) -> str:
    """Serve one request on localhost and return the authorization code."""
    result = {}
    done = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != "/callback":
                self.send_response(404)
                self.end_headers()
                return
            query = urllib.parse.parse_qs(parsed.query)
            if query.get("state", [""])[0] != expected_state:
                result["error"] = "state mismatch (possible forged redirect)"
            elif "error" in query:
                result["error"] = query["error"][0]
            elif "code" in query:
                result["code"] = query["code"][0]
            else:
                result["error"] = "no code in redirect"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            message = "Done. You can close this tab." if "code" in result else "Failed: " + result["error"]
            self.wfile.write(message.encode())
            done.set()

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        if not done.wait(timeout):
            sys.exit("Timed out waiting for the login redirect.")
    finally:
        server.shutdown()
    if "error" in result:
        sys.exit(f"Authorization failed: {result['error']}")
    return result["code"]


def exchange_code(token_url: str, client_id: str, client_secret: str, code: str) -> dict:
    basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    body = urllib.parse.urlencode(
        {
            "code": code,
            "grant_type": "authorization_code",
            "scope": SCOPE,
            "redirect_uri": REDIRECT_URI,
        }
    ).encode()
    request = urllib.request.Request(
        token_url,
        data=body,
        headers={
            "Authorization": f"Basic {basic}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as err:
        sys.exit(f"Token request failed: HTTP {err.code} {err.read().decode(errors='replace')[:300]}")


def list_projects(api_url: str, token: str) -> list:
    request = urllib.request.Request(
        f"{api_url}/project", headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as err:
        sys.exit(f"The token was issued but the API rejected it: HTTP {err.code}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--client-id")
    parser.add_argument("--client-secret")
    parser.add_argument("--utc-offset", type=float, help="hours from UTC, e.g. -5")
    parser.add_argument("--inbox-id", help="Inbox list id, e.g. inbox123456789")
    parser.add_argument("--dida365", action="store_true", help="use dida365.com instead of ticktick.com")
    parser.add_argument("--out", default="ticktick.lua")
    parser.add_argument("--no-browser", action="store_true", help="print the login URL instead of opening it")
    parser.add_argument("--timeout", type=int, default=300, help="seconds to wait for the login")
    # Test hooks.
    parser.add_argument("--auth-url", help=argparse.SUPPRESS)
    parser.add_argument("--token-url", help=argparse.SUPPRESS)
    parser.add_argument("--api-url", help=argparse.SUPPRESS)
    args = parser.parse_args()

    service = SERVICES["dida365" if args.dida365 else "ticktick"]
    auth_url = args.auth_url or service["auth"]
    token_url = args.token_url or service["token"]
    api_url = args.api_url or service["api"]

    client_id = args.client_id or input("Client ID: ").strip()
    client_secret = args.client_secret or getpass.getpass("Client secret: ").strip()
    if not client_id or not client_secret:
        sys.exit("Client ID and secret are required.")

    state = secrets.token_urlsafe(16)
    login_url = auth_url + "?" + urllib.parse.urlencode(
        {
            "client_id": client_id,
            "scope": SCOPE,
            "state": state,
            "redirect_uri": REDIRECT_URI,
            "response_type": "code",
        }
    )
    print("Open this page and approve access:\n  " + login_url, flush=True)
    if not args.no_browser:
        webbrowser.open(login_url)

    code = wait_for_code(state, args.timeout)
    token_response = exchange_code(token_url, client_id, client_secret, code)
    token = token_response.get("access_token")
    if not token:
        sys.exit(f"No access_token in response: {token_response}")

    projects = list_projects(api_url, token)
    print(f"Token works. {len(projects)} lists found:")
    for project in projects:
        print(f"  - {project.get('name')}  ({project.get('id')})")

    settings = {"access_token": token}
    if args.dida365:
        settings["base_url"] = api_url
    if args.utc_offset is not None:
        settings["utc_offset_minutes"] = int(round(args.utc_offset * 60))
    if args.inbox_id:
        settings["extra_project_ids"] = [args.inbox_id]

    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(render_settings(settings))
    try:
        import os

        os.chmod(args.out, 0o600)
    except OSError:
        pass
    expires = token_response.get("expires_in")
    print(f"\nWrote {args.out}. Copy it to koreader/settings/ on the Kindle.")
    if expires:
        print(f"TickTick says the token lasts about {round(int(expires) / 86400)} days; run this again when it stops working.")
    print("Treat that file like a password.")


if __name__ == "__main__":
    main()
