#!/usr/bin/env node
/**
 * Apple Music MCP server (zero dependencies).
 *
 * Wraps macOS Music.app via AppleScript (osascript) and exposes it as MCP
 * tools over the stdio transport (newline-delimited JSON-RPC 2.0).
 *
 * Designed to "just work" while vibe coding: say what you want, it plays.
 */

const { execFile } = require("node:child_process");

const SERVER_NAME = "apple-music";
const SERVER_VERSION = "1.0.0";
const PROTOCOL_VERSION = "2024-11-05";

/* ------------------------------------------------------------------ */
/* AppleScript helpers                                                 */
/* ------------------------------------------------------------------ */

/** Run an AppleScript snippet and resolve its stdout (trimmed). */
function osa(script) {
  return new Promise((resolve, reject) => {
    execFile("osascript", ["-e", script], { timeout: 15000 }, (err, stdout, stderr) => {
      if (err) {
        reject(new Error((stderr || err.message || "osascript failed").trim()));
        return;
      }
      resolve((stdout || "").trim());
    });
  });
}

/** Escape a JS string for safe embedding inside an AppleScript "..." literal.
 *  Control chars (newlines etc.) are stripped first so input can never break out
 *  of the string literal; then backslash and quote are escaped. */
function esc(s) {
  return String(s)
    .replace(/[\x00-\x1f\x7f]/g, " ")
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"');
}

/** Make sure Music.app is running before we try to drive it. */
async function ensureRunning() {
  await osa('tell application "Music" to if it is not running then activate');
}

/** Human-readable description of what's currently playing. */
async function nowPlaying() {
  const state = await osa('tell application "Music" to get player state');
  if (state !== "playing" && state !== "paused") {
    return `Music is ${state} — nothing loaded.`;
  }
  const info = await osa(
    'tell application "Music"\n' +
      "  set t to current track\n" +
      '  set out to (name of t) & " — " & (artist of t) & " — " & (album of t)\n' +
      '  try\n    set out to out & " | " & (name of current playlist)\n  end try\n' +
      "  return out\n" +
      "end tell"
  );
  const vol = await osa('tell application "Music" to get sound volume');
  const verb = state === "playing" ? "▶ Playing" : "⏸ Paused";
  return `${verb}: ${info} (volume ${vol})`;
}

/* ------------------------------------------------------------------ */
/* Tool implementations                                                */
/* ------------------------------------------------------------------ */

const tools = {
  music_now_playing: {
    schema: {
      name: "music_now_playing",
      description: "Show the current track, artist, album, playlist, play state, and volume.",
      inputSchema: { type: "object", properties: {} },
    },
    run: async () => nowPlaying(),
  },

  music_play: {
    schema: {
      name: "music_play",
      description:
        "Play music. With no query, resumes/starts playback. With a query, searches your " +
        "library for a matching song, artist, or album and plays it.",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", description: "Optional song, artist, or album to search for and play." },
        },
      },
    },
    run: async ({ query } = {}) => {
      await ensureRunning();
      if (!query || !query.trim()) {
        await osa('tell application "Music" to play');
        return await nowPlaying();
      }
      const q = esc(query.trim());
      const played = await osa(
        'tell application "Music"\n' +
          `  set results to (every track of library playlist 1 whose name contains "${q}" or artist contains "${q}" or album contains "${q}")\n` +
          "  if (count of results) is 0 then return \"NO_MATCH\"\n" +
          "  play (item 1 of results)\n" +
          "  return \"OK\"\n" +
          "end tell"
      );
      if (played === "NO_MATCH") {
        return `No library match for "${query}". Try a playlist, or add it to your library first.`;
      }
      return await nowPlaying();
    },
  },

  music_pause: {
    schema: { name: "music_pause", description: "Pause playback.", inputSchema: { type: "object", properties: {} } },
    run: async () => {
      await osa('tell application "Music" to pause');
      return "⏸ Paused.";
    },
  },

  music_next: {
    schema: { name: "music_next", description: "Skip to the next track.", inputSchema: { type: "object", properties: {} } },
    run: async () => {
      await ensureRunning();
      await osa('tell application "Music" to next track');
      return await nowPlaying();
    },
  },

  music_previous: {
    schema: {
      name: "music_previous",
      description: "Go to the previous track.",
      inputSchema: { type: "object", properties: {} },
    },
    run: async () => {
      await ensureRunning();
      await osa('tell application "Music" to previous track');
      return await nowPlaying();
    },
  },

  music_set_volume: {
    schema: {
      name: "music_set_volume",
      description: "Set Music app volume (0-100).",
      inputSchema: {
        type: "object",
        properties: { level: { type: "number", description: "Volume 0-100." } },
        required: ["level"],
      },
    },
    run: async ({ level }) => {
      const v = Math.max(0, Math.min(100, Math.round(Number(level))));
      if (Number.isNaN(v)) throw new Error("level must be a number 0-100");
      await osa(`tell application "Music" to set sound volume to ${v}`);
      return `🔊 Volume set to ${v}.`;
    },
  },

  music_play_playlist: {
    schema: {
      name: "music_play_playlist",
      description: "Play a playlist by name (partial match works).",
      inputSchema: {
        type: "object",
        properties: { name: { type: "string", description: "Playlist name." } },
        required: ["name"],
      },
    },
    run: async ({ name }) => {
      await ensureRunning();
      const q = esc(name.trim());
      const res = await osa(
        'tell application "Music"\n' +
          `  set pls to (every playlist whose name contains "${q}")\n` +
          "  if (count of pls) is 0 then return \"NO_MATCH\"\n" +
          "  play (item 1 of pls)\n" +
          "  return \"OK\"\n" +
          "end tell"
      );
      if (res === "NO_MATCH") return `No playlist matching "${name}".`;
      return await nowPlaying();
    },
  },

  music_shuffle: {
    schema: {
      name: "music_shuffle",
      description: "Turn shuffle on or off.",
      inputSchema: {
        type: "object",
        properties: { enabled: { type: "boolean", description: "true = shuffle on, false = off." } },
        required: ["enabled"],
      },
    },
    run: async ({ enabled }) => {
      await osa(`tell application "Music" to set shuffle enabled to ${enabled ? "true" : "false"}`);
      return `🔀 Shuffle ${enabled ? "on" : "off"}.`;
    },
  },

  music_list_playlists: {
    schema: {
      name: "music_list_playlists",
      description: "List your playlists (handy when you forget the exact name).",
      inputSchema: { type: "object", properties: {} },
    },
    run: async () => {
      const out = await osa(
        'tell application "Music" to get name of every user playlist'
      );
      return out ? out.split(", ").map((p) => `• ${p}`).join("\n") : "No playlists found.";
    },
  },
};

/* ------------------------------------------------------------------ */
/* MCP stdio JSON-RPC plumbing                                         */
/* ------------------------------------------------------------------ */

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function reply(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function replyError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handle(msg) {
  const { id, method, params } = msg;

  if (method === "initialize") {
    reply(id, {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
    });
    return;
  }

  if (method === "notifications/initialized" || method === "notifications/cancelled") {
    return; // notifications: no response
  }

  if (method === "tools/list") {
    reply(id, { tools: Object.values(tools).map((t) => t.schema) });
    return;
  }

  if (method === "tools/call") {
    const tool = tools[params && params.name];
    if (!tool) {
      replyError(id, -32602, `Unknown tool: ${params && params.name}`);
      return;
    }
    try {
      const text = await tool.run(params.arguments || {});
      reply(id, { content: [{ type: "text", text }] });
    } catch (e) {
      reply(id, { content: [{ type: "text", text: `Error: ${e.message}` }], isError: true });
    }
    return;
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
    try {
      msg = JSON.parse(line);
    } catch {
      continue;
    }
    handle(msg).catch((e) => {
      if (msg && msg.id !== undefined) replyError(msg.id, -32603, e.message);
    });
  }
});

process.stdin.on("end", () => process.exit(0));
