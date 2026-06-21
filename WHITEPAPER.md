# A Secure, Reproducible Claude Code MCP Configuration

**A technical white paper on running Model Context Protocol (MCP) servers under
Claude Code with read-only-by-default security, persistent Gmail OAuth2, and a fix
for a Node.js v26 transport regression.**

Version 1.0 · 2026-06-20

---

## Abstract

This paper documents a production configuration for [Claude Code](https://claude.com/claude-code)
that connects several MCP servers (Gmail, GitHub, filesystem, memory, web fetch,
and two browser-automation servers) under a **default-deny write policy**, while
keeping read and browser-automation tools fully available. It contributes:

1. A **persistent Gmail integration** using OAuth2 refresh tokens, so the user
   authenticates exactly once.
2. A **diagnosis and fix** for an `Invalid response body … Premature close` failure
   that affects the `googleapis`/`gaxios` HTTP stack on **Node.js v26+**.
3. A **read-only security model** for MCP tools, including a non-obvious tool-name
   matching rule that determines whether the policy is actually enforced.
4. A **reproducible setup script** with pinned dependencies, externalized secrets,
   and a clean, secret-free git history.

Everything here is derived from real debugging; the configuration files referenced
live alongside this document.

---

## 1. Motivation

Claude Code can call external tools through MCP servers. That power is also the risk:
an agent with a writable Gmail tool can send or delete mail; a writable GitHub tool
can push or merge. The goals for this setup were:

- **Least privilege by default.** Data servers should be *read-only* unless a write
  is explicitly enabled.
- **No repeated logins.** Gmail should authenticate once and stay authenticated.
- **Browser automation stays free.** Playwright/Puppeteer are inherently
  action-based and were intentionally exempted from the read-only policy.
- **Reproducible and safe to share.** A new machine should be restorable from a
  script, and the configuration repository must contain no secrets.

---

## 2. Architecture

| Layer | Choice |
|-------|--------|
| Host | Claude Code (CLI) on macOS, Node.js v26 |
| MCP servers | playwright, puppeteer, gmail, github, filesystem, memory, sequential-thinking, fetch |
| Gmail auth | OAuth2 *installed-app* flow, refresh-token persisted to disk |
| Policy | `~/.claude/settings.json` `permissions.deny` (default-deny writes) |
| Restore | `setup.sh` (pinned versions) + gitignored `secrets.sh` |

### 2.1 Gmail via OAuth2 refresh tokens

The Gmail MCP server uses the OAuth2 *installed application* flow:

1. A one-time browser authorization grants the requested scopes
   (`gmail.readonly`, `gmail.send`, `gmail.modify`, `gmail.labels`).
2. Google returns an **authorization code** to a localhost callback
   (`http://localhost:44000/oauth2callback`).
3. The code is exchanged for an **access token** (short-lived) and a
   **refresh token** (long-lived).
4. Credentials are stored at `~/.gmail-mcp/token.json` in the
   `google-auth-library` shape: `access_token`, `refresh_token`, `scope`,
   `token_type`, and `expiry_date` (epoch **milliseconds**).

Because the refresh token does not expire under normal use, the access token is
silently renewed and the user never logs in again. The token file is `chmod 600`
and is excluded from version control.

---

## 3. The Node.js v26 "Premature close" problem

### 3.1 Symptom

After authentication succeeded, **every** Gmail API call failed:

```
Invalid response body while trying to fetch
https://gmail.googleapis.com/gmail/v1/users/me/messages?...: Premature close
```

### 3.2 Diagnosis

The failure was isolated with a sequence of controlled experiments:

| Experiment | Result |
|-----------|--------|
| Direct `https`/`urllib` call with the saved token | ✅ works |
| Direct Node `fetch()` (undici) to the same URL | ✅ works |
| The server's own `googleapis` library (`messages.list`) | ❌ `Premature close` |

This narrowed the fault to the **library's HTTP transport**, not the token, the
network, or Node's `fetch`. The relevant versions were `googleapis@140`,
`gaxios@6.7.1`, on **Node v26.3.1**. `gaxios` 6.x defaults to a legacy
Node `https` stream transport whose behavior regressed on Node 26 (an LTS-ahead
release), causing the response stream to close before the body completed.

### 3.3 Fix

`gaxios` accepts a per-request `fetchImplementation`. Supplying the global
`fetch` (undici) bypasses the broken transport. To apply this to a server we do
not control, a tiny preload patches `gaxios` in-process:

```js
// loaded via NODE_OPTIONS="--require .../gaxios-fetch-patch.js"
const Module = require('module');
const origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  const mod = origLoad.apply(this, arguments);
  const proto = mod && mod.Gaxios && mod.Gaxios.prototype;
  if (proto && typeof proto.request === 'function' && !proto.request.__fetchPatched) {
    const orig = proto.request;
    const wrapped = function (opts = {}) {
      if (opts.fetchImplementation === undefined && typeof globalThis.fetch === 'function') {
        opts.fetchImplementation = globalThis.fetch;
      }
      return orig.call(this, opts);
    };
    wrapped.__fetchPatched = true;
    proto.request = wrapped;
  }
  return mod;
};
```

Design notes:
- It hooks the **module loader**, so it works regardless of where `gaxios` is
  hoisted in the `npx` cache.
- It patches **every distinct `Gaxios` class** loaded (guarded by a marker), not
  just the first — robust to multiple hoisted copies.
- It is wired in via the MCP server's `NODE_OPTIONS` env, so it loads before any
  API call.

**Alternative fix:** run the server on Node 20/22 LTS, where `gaxios` 6.x works
unmodified.

---

## 4. Security model

### 4.1 Default-deny writes

`settings.json` denies any MCP tool whose name contains a mutating verb
(`write`, `create`, `delete`, `send`, `modify`, `update`, `add`, `edit`, `move`,
`merge`, `mark`, `draft`, … ~65 verbs).

### 4.2 The matching rule that actually matters

Claude Code matches deny patterns **glob-style against the full tool id**
`mcp__<server>__<tool>`. The subtlety:

- Some servers name tools **verb-first**: `mcp__filesystem__edit_file`.
- Others **prefix the server name**: `mcp__gmail__gmail_send_email`.

A pattern `mcp__*__send*` requires the tool segment to *start* with `send`. It
matches `send_email` but **not** `gmail_send_email` — so naïve rules silently fail
to block the most dangerous Gmail tools. The correct, robust form places a wildcard
**before** the verb:

```
mcp__*__*send*      ✅ matches gmail_send_email, send_email, and edit_send_x
mcp__*__send*       ❌ misses gmail_send_email
```

This setup uses the `mcp__*__*<verb>*` form, plus explicit full-name denies for the
highest-risk tools as defense in depth.

### 4.3 deny beats allow

Rules evaluate in the order **deny → ask → allow**, and specificity does not change
that order. A deny cannot be overridden by a narrower allow. **To enable a write
tool, remove or narrow its deny rule — do not add an allow.**

### 4.4 Browser-automation exemption

Playwright and Puppeteer are action tools by nature (click, type, navigate). They
are intentionally left unrestricted. Because four mutating verbs collide with
browser tool names (`run`→`browser_run_code_unsafe`, `close`→`browser_close`,
`drop`→`browser_drop`, `upload`→`browser_file_upload`), those four verbs are scoped
to the **data servers only** rather than applied globally. A generator + verifier
checks the final rule set against a catalog of known tools and asserts: every write
tool is blocked; every read and browser tool remains callable.

### 4.5 Secrets, supply chain, and history hygiene

- **Secrets** (GitHub PAT, Gmail client id/secret) are loaded from a gitignored
  `secrets.sh` or environment variables — never written into tracked files.
- `.gitignore` excludes `*credentials*`, `*token.json*`, `.gmail-mcp/`,
  `secrets.sh`, and `settings.local.json`.
- **Dependencies are pinned** in `setup.sh`; `@latest` would execute whatever code
  is newest at install time, with credentials in the environment.
- The repository history was rebuilt as a single commit authored with a GitHub
  **noreply** address, so no personal email or placeholder token text appears in
  any commit.

---

## 5. Quality assurance

The configuration was reviewed in a loop with an independent agent (OpenAI Codex)
until it returned *SAFE TO PUBLISH*, and cross-checked with a purpose-built
verifier:

- **Secret scanning** of the working tree and full git history (per-pattern:
  OAuth client secret, `ya29.` access tokens, `1//` refresh tokens, `gh*_` PATs,
  private keys, personal email).
- **Independent review** caught: incomplete deny verbs, unpinned packages, a
  secrets-in-script workflow, an over-broad filesystem grant, and a patch that only
  covered the first `gaxios` instance — all addressed.
- **Self-review caught what the independent review missed:** the prefix-matching
  gap in §4.2 that left Gmail writes unblocked.
- **Catalog verifier**: 14 write tools blocked, 37 read tools free, 30 browser
  tools free.

---

## 6. Restore on a new machine

```bash
git clone <this-repo> && cd <repo>
cp secrets.sh.example secrets.sh     # fill in; secrets.sh is gitignored
bash setup.sh                        # installs pinned MCP servers + settings
# First Gmail tool use opens a browser once for OAuth2; the refresh token persists.
```

See `README.md` for the file-by-file inventory and `setup.sh` for the exact steps.

---

## 7. Threat model and limitations

- **In scope:** preventing accidental/unauthorized writes by MCP data tools;
  avoiding secret leakage in a public repository; supply-chain exposure from
  unpinned packages; never-expiring credentials living only on the local disk.
- **Not a sandbox.** The deny list is verb-based pattern matching, not a kernel
  sandbox. A write tool named with a verb outside the list would not be caught —
  **review the deny list against each server's actual tool names.**
- **Local trust.** `~/.gmail-mcp/token.json` grants Gmail access to anyone who can
  read it; it relies on filesystem permissions (`600`) and disk encryption.
- **Pinned versions age.** Pins must be bumped deliberately; review changelos before
  upgrading servers that receive credentials.

---

## 8. File inventory

| File | Purpose |
|------|---------|
| `setup.sh` | Restores all MCP servers (pinned) + copies settings |
| `settings.json` | `permissions.deny` read-only policy + enabled plugins |
| `gaxios-fetch-patch.js` | Node 26 `Premature close` fix (loaded via `NODE_OPTIONS`) |
| `secrets.sh.example` | Template for the gitignored `secrets.sh` |
| `settings.local.json.example` | Local Bash-permission allowlist template |
| `.gitignore` | Excludes all credentials, tokens, and local secrets |
| `README.md` | Quick start + reference |
| `WHITEPAPER.md` | This document |

---

*Generated with [Claude Code](https://claude.com/claude-code). No secrets or
personal data are contained in this repository.*
