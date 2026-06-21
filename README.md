# Claude Code Configuration

Backup + restore for Claude Code MCP servers, settings, and permissions —
**read-only by default**, persistent Gmail OAuth2, and a fix for a Node.js v26
HTTP regression. Contains **no secrets**: all credentials are supplied at setup
time via a gitignored `secrets.sh` or environment variables.

📄 **Full design & rationale:** see [WHITEPAPER.md](WHITEPAPER.md).

## Quick start

```bash
git clone <this-repo> && cd <repo>
cp secrets.sh.example secrets.sh     # fill in your tokens; secrets.sh is gitignored
bash setup.sh                        # installs pinned MCP servers + read-only settings
```
First Gmail tool use opens a browser **once** for OAuth2; the refresh token then
persists and you never log in again.

## What's in here

| File | Purpose |
|------|---------|
| `settings.json` | Global permissions (read-only MCP deny rules) + enabled plugins |
| `settings.local.json.example` | Bash permission allowlist template (no secrets) |
| `secrets.sh.example` | Template for your secrets (copy to gitignored `secrets.sh`) |
| `setup.sh` | Restores all MCP servers (pinned versions) on a new machine |
| `statusline.sh` | Status bar: model / folder / branch / context / cost (Claude session + Codex-today estimate + total) — pure-local, no network |
| `mcp-servers/apple-music/` | Zero-dependency Apple Music MCP server (AppleScript wrapper) |
| `gaxios-fetch-patch.js` | Node 26 fix for the Gmail MCP (see Gmail section) |
| `WHITEPAPER.md` | Full technical white paper (architecture, security, the Node 26 fix) |

## MCP Servers

| Server | Package | Purpose |
|--------|---------|---------|
| playwright | @playwright/mcp | Browser automation (Chromium) |
| puppeteer | @modelcontextprotocol/server-puppeteer | Chrome control + extension interaction |
| gmail | gmail-mcp-server | Gmail read/search (write disabled by default) |
| github | @modelcontextprotocol/server-github | GitHub repos, PRs, issues |
| filesystem | @modelcontextprotocol/server-filesystem | Local file access |
| memory | @modelcontextprotocol/server-memory | Persistent memory across sessions |
| sequential-thinking | @modelcontextprotocol/server-sequential-thinking | Structured reasoning |
| fetch | mcp-server-fetch | Web fetch |
| apple-music | local (`mcp-servers/apple-music`) | Control Music.app by voice: play/pause/next, search & play library tracks, playlists, volume, shuffle |

## Action-approval policy

The governing rule for the assistant operating this setup — tiered by blast radius:

| Tier | Action | Gate |
|------|--------|------|
| 0 | **Anything via MCP, by default** | **Read-only.** Writes/sends are off unless a specific task calls for one. |
| 1 | Enabling a write/send | Per-task and temporary; reverted to read-only after. Never permanently allow-listed. |
| 2 | **Money** — purchases, payments, fintech, billing, account/financial actions | **Direct, explicit approval** for that specific action, every time. |
| 3 | **Sending to anyone** — email, message, post, submission | **Double approval (2×)** — two separate explicit confirmations before it goes out. |

Returning information/analysis to the user is always fine. Acting *out into the
world* (spending money, sending to others) is gated as above.

**These tiers apply to the action, not the tool.** They hold whether the action is
performed via MCP, **browser automation**, AppleScript, Bash, or a direct API call.
Browser automation (Playwright/Puppeteer) is unrestricted for *navigation and
interaction*, but a browser-driven purchase, payment, or send-to-someone still
requires the Tier 2/3 approval — a website is not a loophole.

Two layers enforce this: (1) the `settings.json` deny list hard-blocks MCP
write/send tools (the technical backstop for Tier 0); (2) for paths that can't be
safely verb-blocked without breaking legitimate use (browser, AppleScript, Bash),
the assistant enforces the gates **behaviorally**. The behavioral policy — not just
the deny list — is the real control.

## Security model

Data MCP servers are **read-only by default**. `settings.json` denies any MCP tool
whose name contains a mutating verb (`write`, `create`, `delete`, `send`, `modify`,
`update`, `add`, `edit`, `move`, `merge`, `mark`, `draft`, … — ~65 verbs), using
patterns of the form `mcp__*__*<verb>*`. The leading `*` before the verb is
**essential**: it catches tools whose name is server-prefixed, e.g. Gmail's
`gmail_send_email` (a plain `mcp__*__send*` would NOT match it). The list also
includes explicit full-name denies for the highest-risk tools as belt-and-suspenders.

**Browser automation is intentionally exempt.** `playwright` and `puppeteer` are not
restricted (the user wants free browser control), so the four verbs that collide
with browser tool names (`run`, `close`, `drop`, `upload` — e.g. `browser_close`,
`browser_file_upload`) are scoped to the data servers only rather than applied
globally. The generator + verifier in this repo's history confirms: all known
write tools are blocked, all read and browser tools remain free.

**Secrets never enter LLM context.** `settings.json` also denies the `Read` tool on
sensitive files — `.env`, `*.pem`/`*.key`, SSH/AWS/GCP/Kube/Docker creds, `.npmrc`,
`.netrc`, keychains, service-account JSON, `~/.gmail-mcp/`, `~/.claude.json`, etc. —
so those files are never read into the model's context (and thus never sent to any
LLM vendor). This is a blocklist, not a sandbox: it covers the common secret files
without over-blocking ordinary source code. The strongest data guarantees are
**(a)** keeping secrets out of context (here), **(b)** your account's data-retention
setting / zero-data-retention, and **(c)** not piping data to extra LLM vendors.

⚠️ **`deny` always beats `allow`** (rules evaluate deny → ask → allow; specificity
does not change this). So to enable a specific write tool, **remove or narrow the
matching deny rule** — adding an `allow` rule will NOT override a deny.

Other hardening in `setup.sh`:
- **Pinned MCP versions** — avoids running arbitrary `@latest` code at install time.
- **Filesystem MCP** defaults to read access of `$HOME`; set `FS_ROOT` to narrow it.
- **Secrets** are loaded from a gitignored `secrets.sh` (or env vars), never committed.

## Restore on a new machine

1. Install Claude Code: https://claude.ai/code
2. Install Homebrew
3. Clone this repo: `git clone <this-repo>`
4. Provide your secrets without committing them — copy the template and fill it in:
   ```bash
   cp secrets.sh.example secrets.sh    # secrets.sh is gitignored
   # edit secrets.sh with your real values, OR export them as env vars:
   #   export GITHUB_PERSONAL_ACCESS_TOKEN=<token>
   #   export GMAIL_CLIENT_ID=<id>
   #   export GMAIL_CLIENT_SECRET=<secret>
   ```
5. Run: `bash setup.sh`
6. For Gmail: first use will open browser for one-time OAuth2 authorization

## Gmail OAuth2 setup (one-time)

1. Go to console.cloud.google.com
2. Create project → Enable Gmail API
3. Create OAuth2 credentials (Desktop App type)
4. Add authorized redirect URI: `http://localhost:44000/oauth2callback`
5. Copy Client ID + Client Secret → set as env vars above
6. After `setup.sh` runs, first Gmail tool use triggers browser auth
7. Token stored permanently in `~/.gmail-mcp/token.json` (google-auth-library
   format: `access_token`, `refresh_token`, `scope`, `token_type`, `expiry_date`).
   The refresh token never expires — no re-login ever needed.

### Node 26 "Premature close" fix

`gmail-mcp-server` depends on `googleapis` → `gaxios` 6.x, whose legacy
https-stream transport throws `Invalid response body ... Premature close` on
Node v26+. `setup.sh` installs `gaxios-fetch-patch.js` to `~/.gmail-mcp/` and
loads it via `NODE_OPTIONS="--require ..."` in the gmail MCP env, forcing gaxios
to use the modern global `fetch` (undici) transport. Without this, auth succeeds
but every Gmail API call fails. (Alternative fix: run the server on Node 20/22 LTS.)

## AppleScript

No MCP needed. Claude Code can run AppleScript directly via:
```bash
osascript -e 'tell application "..." to ...'
```
