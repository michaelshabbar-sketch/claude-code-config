#!/usr/bin/env python3
# Claude Code status line — three lines so you can SEE your real usage at a glance:
#
#   Line 1:  📁 folder · 🌿 branch · 🐙 model · 🧠 context%
#   Line 2:  Claude 5h%/wk% (+reset)  |  Codex 5h%/wk%/30d% (+reset)  |  timezone
#   Line 3:  💲 this-session $ · Claude today $ · Codex today ~$ (estimate)
#
# The limit %s are the thing that actually constrains you. Colors go
# green→yellow→red as you approach a limit. Reset times are in your local zone.
#
# Data sources (all LOCAL, no network):
#   - Claude limits + cost + context: the JSON Claude Code pipes in on stdin
#     (rate_limits.five_hour / .seven_day, context_window.used_percentage, cost).
#   - Codex limits + usage: ~/.codex/sessions/*.jsonl (rate_limits.primary/secondary,
#     total_token_usage). Codex $ is ESTIMATED at gpt-5.5 rates (you're on the free
#     ChatGPT plan, so it's notional, hence ~).
import sys, json, os, subprocess, datetime, glob, re, time

HOME = os.path.expanduser("~")

# --- gpt-5.5 API pricing, USD per 1M tokens (edit if rates change) ---
PRICE_IN, PRICE_CACHED, PRICE_OUT = 5.00, 0.50, 30.00

CODEX_CACHE = os.path.join(HOME, ".codex", ".statusline_cache.json")
CODEX_TTL = 60  # seconds
SESS_DIR = os.path.join(HOME, ".claude", ".statusline_sessions")
SESS_TTL = 24 * 3600  # Claude "today" cost ledger: forget a session after 24h idle

RESET = "\033[0m"
def c(code, s): return f"\033[{code}m{s}{RESET}"
def dim(s): return c("2", s)
def sev(pct):  # color by how close to the limit
    return "1;32" if pct < 50 else "1;33" if pct < 80 else "1;31"

try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = {}


def fmt_reset(ts):
    """Local-time reset: '10:50pm' today · 'Sun 4:00am' this week · 'Jul 20' beyond."""
    if not ts:
        return "?"
    dt = datetime.datetime.fromtimestamp(ts)
    days = (dt.date() - datetime.date.today()).days
    if days <= 0:
        return dt.strftime("%-I:%M%p").lower()
    if days <= 6:
        return dt.strftime("%a ") + dt.strftime("%-I:%M%p").lower()
    return dt.strftime("%b %-d")


def win_label(minutes):
    """43200 -> '30d', 10080 -> '7d', 300 -> '5h'."""
    if not minutes:
        return "?"
    if minutes % 1440 == 0:
        return f"{minutes // 1440}d"
    if minutes % 60 == 0:
        return f"{minutes // 60}h"
    return f"{minutes}m"


# ── Claude "today" cost ledger (sum across all recent windows) ────────────────
def claude_today_cost(session_id, this_cost):
    now = time.time()
    try:
        os.makedirs(SESS_DIR, exist_ok=True)
        if session_id:
            with open(os.path.join(SESS_DIR, session_id + ".json"), "w") as fh:
                json.dump({"cost": this_cost, "ts": now}, fh)
    except Exception:
        pass
    total, counted_self = 0.0, False
    try:
        for fn in os.listdir(SESS_DIR):
            if not fn.endswith(".json"):
                continue
            path = os.path.join(SESS_DIR, fn)
            try:
                with open(path) as fh:
                    rec = json.load(fh)
            except Exception:
                continue
            if now - rec.get("ts", 0) > SESS_TTL:
                try: os.remove(path)
                except Exception: pass
                continue
            total += rec.get("cost", 0.0) or 0.0
            if session_id and fn == session_id + ".json":
                counted_self = True
    except Exception:
        pass
    return total if counted_self else max(total, this_cost)


# ── Codex: today's estimated $ + latest rate limits (cached together) ─────────
def _find_key(obj, key):
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for v in obj.values():
            r = _find_key(v, key)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = _find_key(v, key)
            if r is not None:
                return r
    return None


def _usage_cost(u):
    inp = u.get("input_tokens", 0) or 0
    cached = u.get("cached_input_tokens", 0) or 0
    out = u.get("output_tokens", 0) or 0
    return (max(0, inp - cached) * PRICE_IN + cached * PRICE_CACHED + out * PRICE_OUT) / 1_000_000


def _last_usage(path):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > 65536:
                fh.seek(size - 65536)
            tail = fh.read().decode("utf-8", "ignore")
    except Exception:
        return None
    m = re.findall(r'"total_token_usage":(\{[^}]*\})', tail)
    if not m:
        return None
    try:
        return json.loads(m[-1])
    except Exception:
        return None


def codex_state():
    """Returns {'cost': today_usd, 'limits': [{label,pct,reset}, ...]}, cached."""
    now = time.time()
    try:
        with open(CODEX_CACHE) as fh:
            cached = json.load(fh)
        if now - cached.get("ts", 0) < CODEX_TTL:
            return cached
    except Exception:
        pass

    # today's estimated cost
    today = datetime.date.today()
    day_dir = os.path.join(HOME, ".codex", "sessions",
                           f"{today.year:04d}", f"{today.month:02d}", f"{today.day:02d}")
    cost = 0.0
    for p in glob.glob(os.path.join(day_dir, "*.jsonl")):
        u = _last_usage(p)
        if u:
            cost += _usage_cost(u)

    # latest rate limits: newest session that actually recorded them wins
    limits = []
    try:
        files = glob.glob(os.path.join(HOME, ".codex", "sessions", "*", "*", "*", "*.jsonl"))
        files.sort(key=os.path.getmtime, reverse=True)
        rl = None
        for path in files[:20]:
            found = None
            for line in open(path, encoding="utf-8", errors="ignore"):
                if '"rate_limits"' not in line:
                    continue
                try:
                    found = _find_key(json.loads(line), "rate_limits") or found
                except Exception:
                    continue
            if isinstance(found, dict) and (found.get("primary") or found.get("secondary")):
                rl = found
                break  # newest file with real limit data
        if isinstance(rl, dict):
            for slot in ("primary", "secondary"):
                    w = rl.get(slot)
                    if isinstance(w, dict) and w.get("used_percent") is not None:
                        limits.append({
                            "label": win_label(w.get("window_minutes")),
                            "pct": round(w.get("used_percent", 0)),
                            "reset": fmt_reset(w.get("resets_at")),
                        })
    except Exception:
        pass

    out = {"ts": now, "cost": cost, "limits": limits}
    try:
        with open(CODEX_CACHE, "w") as fh:
            json.dump(out, fh)
    except Exception:
        pass
    return out


# ── Line 1: folder · branch · model · context% ───────────────────────────────
ws = d.get("workspace") or {}
cwd = ws.get("current_dir") or d.get("cwd") or os.getcwd()
path = cwd.replace(HOME, "~")
model = (d.get("model") or {}).get("display_name") or "Claude"

branch = ""
try:
    b = subprocess.run(["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
                       capture_output=True, text=True, timeout=1)
    if b.returncode == 0 and b.stdout.strip():
        s = subprocess.run(["git", "-C", cwd, "status", "--porcelain"],
                           capture_output=True, text=True, timeout=1)
        star = "*" if s.stdout.strip() else ""
        branch = "  " + c("1;32", f"🌿 {b.stdout.strip()}{star}")
except Exception:
    pass

ctx_seg = ""
try:
    up = (d.get("context_window") or {}).get("used_percentage")
    if up is not None:
        u = int(round(up))
        ctx_seg = "  " + c(sev(u), f"🧠 ctx:{u}%")
except Exception:
    pass

line1 = c("1;36", f"📁 {path}") + branch + "  " + c("1;35", f"🐙 {model}") + ctx_seg

# ── Line 2: Claude limits | Codex limits | timezone ──────────────────────────
def claude_limit_seg():
    rl = d.get("rate_limits") or {}
    parts = []
    for key, lbl in (("five_hour", "5h"), ("seven_day", "wk")):
        w = rl.get(key)
        if isinstance(w, dict) and w.get("used_percentage") is not None:
            p = int(round(w["used_percentage"]))
            parts.append(c(sev(p), f"{lbl} {p}%") + dim(f"↻{fmt_reset(w.get('resets_at'))}"))
    return c("1", "Claude ") + " · ".join(parts) if parts else ""

cx = codex_state()
def codex_limit_seg():
    if not cx.get("limits"):
        return c("1", "Codex ") + dim("—")
    parts = [c(sev(l["pct"]), f"{l['label']} {l['pct']}%") + dim(f"↻{l['reset']}")
             for l in cx["limits"]]
    return c("1", "Codex ") + " · ".join(parts)

tz = datetime.datetime.now().astimezone().tzname() or ""
segs = [s for s in (claude_limit_seg(), codex_limit_seg(), dim(tz)) if s]
line2 = ("  " + dim("|") + "  ").join(segs)

# ── Line 3: this-session $ · Claude today $ · Codex today ~$ ──────────────────
this_cost = float((d.get("cost") or {}).get("total_cost_usd") or 0.0)
cl_today = claude_today_cost(d.get("session_id"), this_cost)
cx_today = cx.get("cost", 0.0)
line3 = (c("1;37", f"💲{this_cost:.2f} sess") + dim(" · ") +
         c("1;33", f"Claude ${cl_today:.2f}") + dim(" · ") +
         c("1;34", f"Codex ~${cx_today:.2f}"))

print(line1)
print(line2)
print(line3)
