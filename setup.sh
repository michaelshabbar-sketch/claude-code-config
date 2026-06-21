#!/bin/bash
# Claude Code Setup — restore MCP servers + settings on a new machine.
#
# Usage:
#   1. Provide secrets WITHOUT committing them — either:
#        a) copy secrets.sh.example to secrets.sh and fill it in (secrets.sh is
#           gitignored), or
#        b) export GITHUB_PERSONAL_ACCESS_TOKEN / GMAIL_CLIENT_ID /
#           GMAIL_CLIENT_SECRET as environment variables.
#      Do NOT paste real secrets into this file — it is committed to git.
#   2. Run: bash setup.sh
#
# Security notes:
#   - MCP package versions are pinned below (supply-chain safety). Review and bump
#     deliberately; `@latest` would run whatever code is newest at install time.
#   - All MCP write operations are denied by settings.json (read-only by default).
#   - The filesystem MCP root defaults to $HOME; narrow it with FS_ROOT for less
#     exposure (e.g. FS_ROOT="$HOME/projects").

set -euo pipefail

# ── Load secrets from gitignored secrets.sh if present (never commit real values) ─
[ -f "./secrets.sh" ] && source ./secrets.sh
GITHUB_PAT="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
GMAIL_CLIENT_ID="${GMAIL_CLIENT_ID:-}"
GMAIL_CLIENT_SECRET="${GMAIL_CLIENT_SECRET:-}"
FS_ROOT="${FS_ROOT:-$HOME}"

# ── Pinned MCP package versions (review before bumping) ───────────────────────
PW_VER="0.0.76"                       # @playwright/mcp
PUPPETEER_VER="2025.5.12"             # @modelcontextprotocol/server-puppeteer
GITHUB_VER="2025.4.8"                 # @modelcontextprotocol/server-github
FILESYSTEM_VER="2026.1.14"            # @modelcontextprotocol/server-filesystem
MEMORY_VER="2026.1.26"                # @modelcontextprotocol/server-memory
SEQTHINK_VER="2025.12.18"            # @modelcontextprotocol/server-sequential-thinking
FETCH_VER="2026.6.4"                  # mcp-server-fetch (PyPI, via uvx)
GMAIL_VER="1.0.30"                    # gmail-mcp-server
# ─────────────────────────────────────────────────────────────────────────────

NPX="/opt/homebrew/bin/npx"
MCP_PATH="PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

echo "Installing Node.js + gh if needed..."
brew install node gh 2>/dev/null || true

echo "Copying Claude Code settings (read-only MCP deny rules)..."
mkdir -p ~/.claude
cp settings.json ~/.claude/settings.json

# Status line: model / folder / branch / context / cost (Claude session +
# Codex-today estimate + total). Pure-local, no network. settings.json points
# Claude Code at ~/.claude/statusline.sh.
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh

# Helper CLIs: imsg (read iMessage by name), imsg-send (send by name, two-phase
# confirm), usage (Claude+Codex spend at a glance).
# Personal contact aliases stay in a local-only ~/.imsg-aliases.json (never committed).
mkdir -p ~/.local/bin
cp tools/imsg ~/.local/bin/imsg && chmod +x ~/.local/bin/imsg
cp tools/imsg-send ~/.local/bin/imsg-send && chmod +x ~/.local/bin/imsg-send
cp tools/usage ~/.local/bin/usage && chmod +x ~/.local/bin/usage

echo "Adding MCP servers (pinned versions)..."

claude mcp add --scope user playwright \
  -e "$MCP_PATH" \
  -- "$NPX" -y "@playwright/mcp@${PW_VER}" --browser chromium

claude mcp add --scope user puppeteer \
  -e "$MCP_PATH" \
  -- "$NPX" -y "@modelcontextprotocol/server-puppeteer@${PUPPETEER_VER}"

# GitHub MCP needs a PAT — skip if not provided
if [[ -n "$GITHUB_PAT" ]]; then
  claude mcp add --scope user github \
    -e GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_PAT" \
    -e "$MCP_PATH" \
    -- "$NPX" -y "@modelcontextprotocol/server-github@${GITHUB_VER}"
else
  echo "Skipped GitHub MCP — set GITHUB_PERSONAL_ACCESS_TOKEN then re-run."
fi

# Filesystem MCP: read access to FS_ROOT (default $HOME). Writes denied by settings.json.
claude mcp add --scope user filesystem \
  -e "$MCP_PATH" \
  -- "$NPX" -y "@modelcontextprotocol/server-filesystem@${FILESYSTEM_VER}" "$FS_ROOT"

claude mcp add --scope user memory \
  -e "$MCP_PATH" \
  -- "$NPX" -y "@modelcontextprotocol/server-memory@${MEMORY_VER}"

claude mcp add --scope user sequential-thinking \
  -e "$MCP_PATH" \
  -- "$NPX" -y "@modelcontextprotocol/server-sequential-thinking@${SEQTHINK_VER}"

claude mcp add --scope user fetch \
  -- uvx --from "mcp-server-fetch==${FETCH_VER}" mcp-server-fetch

# Apple Music: control Music.app by voice while you work (play/pause/next,
# search & play library tracks, playlists, volume, shuffle). Zero dependencies —
# a local Node script wrapping AppleScript. No network, no credentials.
mkdir -p "$HOME/mcp-servers/apple-music"
cp mcp-servers/apple-music/server.js "$HOME/mcp-servers/apple-music/server.js"
claude mcp add --scope user apple-music \
  -- node "$HOME/mcp-servers/apple-music/server.js"

# Spotify: reliable "play any song" with NO credentials. Playback/controls run via
# the Spotify app's AppleScript; a song NAME is resolved to a track id by Claude
# using the Playwright browser tools (Spotify's public search), then played here.
# Only requirement: the Spotify app + a (free) Spotify account logged in.
mkdir -p "$HOME/mcp-servers/spotify"
cp mcp-servers/spotify/server.js "$HOME/mcp-servers/spotify/server.js"
claude mcp add --scope user spotify \
  -- node "$HOME/mcp-servers/spotify/server.js"

# Gmail requires one-time OAuth2 setup — see README.md
if [[ -n "$GMAIL_CLIENT_ID" && -n "$GMAIL_CLIENT_SECRET" ]]; then
  # Install the gaxios fetch patch (fixes "Premature close" on Node v26+).
  # gaxios 6.x (inside googleapis) uses a legacy https-stream transport that
  # regresses on Node 26; this preload forces the modern global fetch transport.
  mkdir -p "$HOME/.gmail-mcp"
  cp gaxios-fetch-patch.js "$HOME/.gmail-mcp/gaxios-fetch-patch.js"

  claude mcp add --scope user gmail \
    -e GMAIL_CLIENT_ID="$GMAIL_CLIENT_ID" \
    -e GMAIL_CLIENT_SECRET="$GMAIL_CLIENT_SECRET" \
    -e "$MCP_PATH" \
    -e NODE_OPTIONS="--require $HOME/.gmail-mcp/gaxios-fetch-patch.js" \
    -- "$NPX" -y "gmail-mcp-server@${GMAIL_VER}"
  echo "Gmail MCP added. First use opens a browser for one-time OAuth2 authorization."
  echo "  (The refresh token is stored in ~/.gmail-mcp/token.json and never expires —"
  echo "   you will not need to log in again.)"
else
  echo "Skipped Gmail — set GMAIL_CLIENT_ID and GMAIL_CLIENT_SECRET then re-run."
fi

echo ""
echo "Done. Run 'claude mcp list' to verify."
