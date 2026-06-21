#!/usr/bin/env node
/**
 * Spotify MCP server (zero dependencies, NO credentials).
 *
 * Playback + controls run through the Spotify desktop app's first-class
 * AppleScript support (deterministic). There are NO API keys: a song NAME is
 * resolved to a track URI by Claude using the Playwright browser tools (reading
 * Spotify's public web pages), then handed to spotify_play_track here. Tool
 * priority Chrome > Playwright > AppleScript — see the user's accessibility setup.
 */

const { execFile } = require("node:child_process");

const SERVER_NAME = "spotify";
const SERVER_VERSION = "2.0.0";
const PROTOCOL_VERSION = "2024-11-05";

function osa(script) {
  return new Promise((resolve, reject) => {
    execFile("osascript", ["-e", script], { timeout: 15000 }, (err, stdout, stderr) => {
      if (err) return reject(new Error((stderr || err.message || "osascript failed").trim()));
      resolve((stdout || "").trim());
    });
  });
}

async function ensureRunning() {
  await osa('tell application "Spotify" to if it is not running then activate');
}

async function nowPlaying() {
  const state = await osa('tell application "Spotify" to player state as string').catch(() => "stopped");
  if (state !== "playing" && state !== "paused") return `Spotify is ${state}.`;
  const vol = await osa('tell application "Spotify" to sound volume').catch(() => "?");
  // The track can be briefly unreadable during a load/transition (-1728); retry.
  let info = "";
  for (let i = 0; i < 3 && !info; i++) {
    info = await osa(
      'tell application "Spotify" to (name of current track) & " — " & (artist of current track) & " — " & (album of current track)'
    ).catch(() => "");
    if (!info) await new Promise((r) => setTimeout(r, 300));
  }
  if (!info) return `${state === "playing" ? "▶ Playing" : "⏸ Paused"} (loading…) (volume ${vol})`;
  return `${state === "playing" ? "▶ Playing" : "⏸ Paused"}: ${info} (volume ${vol})`;
}

/** Accept a bare ID, spotify:track:ID, or an open.spotify.com/track/ID URL. */
function toUri(track) {
  const s = String(track || "").trim();
  let m = s.match(/spotify:track:([A-Za-z0-9]+)/) || s.match(/\/track\/([A-Za-z0-9]+)/) || s.match(/^([A-Za-z0-9]{22})$/);
  if (!m) throw new Error(`Not a Spotify track id/uri/url: "${track}"`);
  return `spotify:track:${m[1]}`;
}

const tools = {
  spotify_play_track: {
    schema: {
      name: "spotify_play_track",
      description:
        "Play a specific Spotify track by URI, id, or open.spotify.com URL. (Resolve a song NAME to an id " +
        "first using the Playwright browser tools on Spotify's public search page, then call this.)",
      inputSchema: {
        type: "object",
        properties: { track: { type: "string", description: "spotify:track:ID, a bare 22-char id, or an open.spotify.com/track/ URL." } },
        required: ["track"],
      },
    },
    run: async ({ track }) => {
      await ensureRunning();
      const uri = toUri(track);
      await osa(`tell application "Spotify" to play track "${uri}"`);
      return await nowPlaying();
    },
  },
  spotify_play: {
    schema: { name: "spotify_play", description: "Resume/start playback.", inputSchema: { type: "object", properties: {} } },
    run: async () => { await ensureRunning(); await osa('tell application "Spotify" to play'); return await nowPlaying(); },
  },
  spotify_pause: {
    schema: { name: "spotify_pause", description: "Pause Spotify.", inputSchema: { type: "object", properties: {} } },
    run: async () => { await osa('tell application "Spotify" to pause'); return "⏸ Paused."; },
  },
  spotify_next: {
    schema: { name: "spotify_next", description: "Next track.", inputSchema: { type: "object", properties: {} } },
    run: async () => { await ensureRunning(); await osa('tell application "Spotify" to next track'); return await nowPlaying(); },
  },
  spotify_previous: {
    schema: { name: "spotify_previous", description: "Previous track.", inputSchema: { type: "object", properties: {} } },
    run: async () => { await ensureRunning(); await osa('tell application "Spotify" to previous track'); return await nowPlaying(); },
  },
  spotify_now_playing: {
    schema: { name: "spotify_now_playing", description: "Show the current track, artist, album, state, and volume.", inputSchema: { type: "object", properties: {} } },
    run: async () => await nowPlaying(),
  },
  spotify_set_volume: {
    schema: {
      name: "spotify_set_volume",
      description: "Set Spotify volume (0-100).",
      inputSchema: { type: "object", properties: { level: { type: "number", description: "0-100" } }, required: ["level"] },
    },
    run: async ({ level }) => {
      const v = Math.max(0, Math.min(100, Math.round(Number(level))));
      if (Number.isNaN(v)) throw new Error("level must be a number 0-100");
      await osa(`tell application "Spotify" to set sound volume to ${v}`);
      return `🔊 Volume ${v}.`;
    },
  },
};

function send(m) { process.stdout.write(JSON.stringify(m) + "\n"); }
function reply(id, result) { send({ jsonrpc: "2.0", id, result }); }
function replyError(id, code, message) { send({ jsonrpc: "2.0", id, error: { code, message } }); }

async function handle(msg) {
  const { id, method, params } = msg;
  if (method === "initialize") {
    return reply(id, { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: {} }, serverInfo: { name: SERVER_NAME, version: SERVER_VERSION } });
  }
  if (method === "notifications/initialized" || method === "notifications/cancelled") return;
  if (method === "tools/list") return reply(id, { tools: Object.values(tools).map((t) => t.schema) });
  if (method === "tools/call") {
    const tool = tools[params && params.name];
    if (!tool) return replyError(id, -32602, `Unknown tool: ${params && params.name}`);
    try {
      const text = await tool.run(params.arguments || {});
      return reply(id, { content: [{ type: "text", text }] });
    } catch (e) {
      return reply(id, { content: [{ type: "text", text: `Error: ${e.message}` }], isError: true });
    }
  }
  if (id !== undefined) replyError(id, -32601, `Method not found: ${method}`);
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    handle(msg).catch((e) => { if (msg && msg.id !== undefined) replyError(msg.id, -32603, e.message); });
  }
});
process.stdin.on("end", () => process.exit(0));
