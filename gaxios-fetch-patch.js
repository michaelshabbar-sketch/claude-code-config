// gaxios-fetch-patch.js
// Workaround for "Premature close" errors when gaxios 6.x (used by googleapis,
// which the gmail-mcp-server depends on) runs on Node v26+. gaxios's legacy
// https-stream transport regresses on Node 26; forcing the modern global fetch
// (undici) transport fixes it.
//
// Installed to ~/.gmail-mcp/gaxios-fetch-patch.js and loaded via
// NODE_OPTIONS="--require <this file>" in the gmail MCP server env (see setup.sh).
// It patches gaxios in-process before the server makes any API calls. It hooks the
// module loader and patches EVERY distinct Gaxios class that gets loaded (each is
// wrapped at most once via a marker), so it works even if multiple gaxios copies
// are hoisted at different paths in the npx cache.
'use strict';
const Module = require('module');
const origLoad = Module._load;

Module._load = function (request, parent, isMain) {
  const mod = origLoad.apply(this, arguments);
  try {
    const proto = mod && mod.Gaxios && mod.Gaxios.prototype;
    if (proto && typeof proto.request === 'function' && !proto.request.__fetchPatched) {
      const origRequest = proto.request;
      const wrapped = function (opts) {
        opts = opts || {};
        if (opts.fetchImplementation === undefined && typeof globalThis.fetch === 'function') {
          opts.fetchImplementation = globalThis.fetch;
        }
        return origRequest.call(this, opts);
      };
      wrapped.__fetchPatched = true;
      proto.request = wrapped;
      if (process.env.GAXIOS_PATCH_DEBUG) {
        console.error('[gaxios-fetch-patch] patched a Gaxios instance to use global fetch');
      }
    }
  } catch (e) {
    if (process.env.GAXIOS_PATCH_DEBUG) console.error('[gaxios-fetch-patch] error:', e.message);
  }
  return mod;
};
