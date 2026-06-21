#!/usr/bin/env python3
"""Read across ALL connected Gmail accounts at once (primary + any added via
add-gmail-account.py). Shows each account's unread count and top unread headers.

Usage:  python3 gmail-read-all.py [N]      # N = unread headers per account (default 5)

Read-only. Auto-refreshes each account's access token from its stored refresh token.
"""
import sys, os, json, time, glob, urllib.parse, urllib.request

N = int(sys.argv[1]) if len(sys.argv) > 1 else 5
HOME = os.path.expanduser("~")

# Discover account config dirs: primary + isolated per-account
dirs = [os.path.join(HOME, ".gmail-mcp")]
dirs += sorted(glob.glob(os.path.join(HOME, ".gmail-accounts", "*", ".gmail-mcp")))

def load_client(cfg):
    c = json.load(open(os.path.join(cfg, "credentials.json")))
    i = c.get("installed") or c.get("web")
    return i["client_id"], i["client_secret"]

def access_token(cfg):
    tp = os.path.join(cfg, "token.json")
    tok = json.load(open(tp))
    if tok.get("expiry_date", 0)/1000 > time.time() + 60:
        return tok["access_token"]
    cid, csec = load_client(cfg)
    data = urllib.parse.urlencode({"client_id": cid, "client_secret": csec,
        "refresh_token": tok["refresh_token"], "grant_type": "refresh_token"}).encode()
    nt = json.loads(urllib.request.urlopen(urllib.request.Request(
        "https://oauth2.googleapis.com/token", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"}), timeout=20).read())
    tok["access_token"] = nt["access_token"]
    tok["expiry_date"] = int(time.time()*1000) + int(nt.get("expires_in", 3599))*1000
    json.dump(tok, open(tp, "w"), indent=2)
    return tok["access_token"]

def api(at, u):
    return json.loads(urllib.request.urlopen(urllib.request.Request(
        u, headers={"Authorization": "Bearer " + at}), timeout=25).read())

found = 0
for cfg in dirs:
    if not os.path.exists(os.path.join(cfg, "token.json")):
        continue
    found += 1
    try:
        at = access_token(cfg)
        prof = api(at, "https://gmail.googleapis.com/gmail/v1/users/me/profile")
        lst = api(at, f"https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults={N}&q=is:unread")
        msgs = lst.get("messages", [])
        print(f"\n=== {prof['emailAddress']}  ({prof['messagesTotal']} total) ===")
        if not msgs:
            print("  (no unread)"); continue
        for i, m in enumerate(msgs, 1):
            md = api(at, f"https://gmail.googleapis.com/gmail/v1/users/me/messages/{m['id']}?format=metadata&metadataHeaders=From&metadataHeaders=Subject")
            h = {x['name']: x['value'] for x in md['payload']['headers']}
            print(f"  {i}. {h.get('From','?')[:34]:34} | {h.get('Subject','(no subject)')[:46]}")
    except Exception as e:
        print(f"\n=== {cfg} ===\n  ERROR: {e}")

if found == 0:
    print("No Gmail accounts configured yet. Add one: python3 add-gmail-account.py <email>")
