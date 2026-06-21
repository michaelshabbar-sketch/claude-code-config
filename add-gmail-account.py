#!/usr/bin/env python3
"""Onboard an additional Gmail account into this multi-account MCP setup.

Usage:  python3 add-gmail-account.py <email> [instance_name]

It reuses the OAuth client already in ~/.gmail-mcp/credentials.json (no secrets are
stored in this file), runs the one-time browser authorization, stores the new
account's refresh token in an isolated per-account directory, verifies access, and
registers an isolated MCP server instance for it. Read-only is enforced globally by
settings.json. Designed so a new account takes seconds: run it, complete one sign-in.

Notes:
- The OAuth app is in "testing" mode, so the target account must be a test user in
  the Google Cloud console first (add it under OAuth consent screen > Test users).
- Accounts are isolated via a per-account HOME so each server sees its own
  ~/.gmail-mcp; npm cache is pinned to the real one to avoid re-downloads.
"""
import sys, os, json, time, urllib.parse, urllib.request, webbrowser, subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler

if len(sys.argv) < 2:
    print("Usage: add-gmail-account.py <email> [instance_name]"); sys.exit(1)
email = sys.argv[1].strip()
instance = (sys.argv[2] if len(sys.argv) > 2 else "gmail-" + email.split("@")[0]).strip()

REAL_HOME = os.path.expanduser("~")
c = json.load(open(os.path.join(REAL_HOME, ".gmail-mcp/credentials.json")))
inst = c.get("installed") or c.get("web")
CLIENT_ID, CLIENT_SECRET = inst["client_id"], inst["client_secret"]
REDIRECT = "http://localhost:44000/oauth2callback"
SCOPES = ["openid", "email", "profile",
          "https://www.googleapis.com/auth/gmail.readonly",
          "https://www.googleapis.com/auth/gmail.send",
          "https://www.googleapis.com/auth/gmail.modify",
          "https://www.googleapis.com/auth/gmail.labels"]

ACCOUNT_HOME = os.path.join(REAL_HOME, ".gmail-accounts", instance)
CONFIG_DIR = os.path.join(ACCOUNT_HOME, ".gmail-mcp")
os.makedirs(CONFIG_DIR, exist_ok=True)
json.dump(c, open(os.path.join(CONFIG_DIR, "credentials.json"), "w"), indent=2)

auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
    "client_id": CLIENT_ID, "redirect_uri": REDIRECT, "response_type": "code",
    "scope": " ".join(SCOPES), "access_type": "offline", "prompt": "consent",
    "login_hint": email, "state": "localhost"})

box = {}
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        self.send_response(200); self.send_header("Content-type", "text/html"); self.end_headers()
        if "code" in q:
            box["code"] = q["code"][0]
            self.wfile.write(b"<h1 style='font-family:sans-serif;color:#0a0'>Account connected. You can close this tab.</h1>")
        else:
            self.wfile.write(b"<h1>Waiting...</h1>")
    def log_message(self, *a): pass

with open("/tmp/add_gmail_auth_url.txt", "w") as f:
    f.write(auth_url)
print(f"INSTANCE:{instance}")
print(f"AUTH_URL_FILE:/tmp/add_gmail_auth_url.txt")
srv = HTTPServer(("localhost", 44000), H); srv.timeout = 1
try: webbrowser.open(auth_url)
except Exception: pass
print("LISTENING_44000")
deadline = time.time() + 300
while "code" not in box and time.time() < deadline:
    srv.handle_request()
srv.server_close()
if "code" not in box:
    print("TIMEOUT_NO_CODE"); sys.exit(1)

data = urllib.parse.urlencode({"code": box["code"], "client_id": CLIENT_ID,
    "client_secret": CLIENT_SECRET, "redirect_uri": REDIRECT,
    "grant_type": "authorization_code"}).encode()
tok = json.loads(urllib.request.urlopen(urllib.request.Request(
    "https://oauth2.googleapis.com/token", data=data,
    headers={"Content-Type": "application/x-www-form-urlencoded"}), timeout=30).read())
creds = {"access_token": tok["access_token"], "refresh_token": tok.get("refresh_token"),
         "scope": tok.get("scope"), "token_type": tok.get("token_type", "Bearer"),
         "expiry_date": int(time.time()*1000) + int(tok.get("expires_in", 3599))*1000}
if "id_token" in tok: creds["id_token"] = tok["id_token"]
tp = os.path.join(CONFIG_DIR, "token.json")
json.dump(creds, open(tp, "w"), indent=2); os.chmod(tp, 0o600)

prof = json.loads(urllib.request.urlopen(urllib.request.Request(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile",
    headers={"Authorization": "Bearer " + creds["access_token"]}), timeout=20).read())
print(f"CONNECTED:{prof['emailAddress']} messages={prof['messagesTotal']} refresh={bool(creds['refresh_token'])}")

patch = os.path.join(REAL_HOME, ".gmail-mcp/gaxios-fetch-patch.js")
subprocess.run(["claude", "mcp", "remove", instance, "--scope", "user"], capture_output=True)
subprocess.run(["claude", "mcp", "add", "--scope", "user", instance,
    "-e", f"GMAIL_CLIENT_ID={CLIENT_ID}", "-e", f"GMAIL_CLIENT_SECRET={CLIENT_SECRET}",
    "-e", f"HOME={ACCOUNT_HOME}", "-e", f"npm_config_cache={REAL_HOME}/.npm",
    "-e", "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
    "-e", f"NODE_OPTIONS=--require {patch}",
    "--", "/opt/homebrew/bin/npx", "-y", "gmail-mcp-server@1.0.30"], capture_output=True)
print(f"REGISTERED_MCP:{instance} home={ACCOUNT_HOME}")
print("DONE")
