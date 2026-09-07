'use strict';
/* ─────────────────────────────────────────────────────────────────────────
 * e2e-smoke-egress-guard.cjs — BUG-20260907-001.
 *
 * Preloaded (`node --require`) into every live-start of smoke-e2e-specs.sh
 * step 2, and ONLY there. Its single job: make it structurally impossible for
 * a spec that the smoke checker starts-then-kills to reach a remote server.
 *
 * Why a runtime guard and not a longer regex: twice now (BUG-20260808-001,
 * BUG-20260907-001) the checker wrote to production because a spec's opening
 * move hit an endpoint nobody had thought to add to a deny-list. A list of
 * forbidden endpoints only ever covers the incidents that already happened.
 * This guard inverts that: during the 5-second start window, NOTHING leaves
 * this process, whatever the spec turns out to call. The static deny-list in
 * smoke-e2e-specs.sh stays as a second layer for the effects this one cannot
 * see (see "Blind spots" below).
 *
 * Method: outbound requests are handed a black-hole socket — a Duplex that
 * swallows what is written to it and never produces a byte back. Deliberately
 * NOT an error:
 *   - a hung request keeps the process alive, which the checker classifies as
 *     "started fine" — exactly the truth we want to report;
 *   - a thrown/ECONNREFUSED error would make the spec exit non-zero within
 *     milliseconds, which the checker would report as "didn't start" — a
 *     fleet of false alarms on healthy files.
 * `fetch()` is neutralised the same way: a promise that never settles.
 *
 * Loopback (127.0.0.1/::1/localhost) is deliberately allowed through. Nothing
 * on production is reachable at loopback, and local transports (a spec's own
 * fixture server, tooling that talks to a local port) must keep working.
 *
 * Blind spots, stated rather than left implicit:
 *   - the CHROMIUM process Playwright spawns has its own network stack; a
 *     `page.evaluate(() => fetch(prod))` is not covered here. That is what the
 *     static deny-list in smoke-e2e-specs.sh covers.
 *   - raw `net.connect` / `dgram` / a subprocess (curl, python) are not
 *     intercepted. No spec in this suite uses them for writes today.
 *
 * Self-test: scripts/test-smoke-e2e-specs.sh (fixtures egress-*.spec.js).
 * ───────────────────────────────────────────────────────────────────────── */

const { Duplex } = require('stream');
const http = require('http');
const https = require('https');

const LOOPBACK = new Set(['localhost', '127.0.0.1', '::1', '[::1]', '0.0.0.0']);

function isLoopbackHost(host) {
  if (!host) return false;
  const bare = String(host).replace(/^\[|\]$/g, '').split(':')[0].toLowerCase();
  return LOOPBACK.has(bare) || LOOPBACK.has(String(host).toLowerCase());
}

/**
 * A socket that accepts everything written to it and answers nothing, ever.
 * The extra no-op methods are the ones node's HTTP client calls on a real
 * net.Socket; without them the client crashes instead of hanging, which would
 * turn this guard into the false-alarm generator described above.
 */
function createBlackHoleSocket() {
  const socket = new Duplex({
    read() {},
    write(_chunk, _enc, cb) { cb(); },
    final(cb) { cb(); },
  });
  socket.setTimeout = () => socket;
  socket.setNoDelay = () => socket;
  socket.setKeepAlive = () => socket;
  socket.ref = () => socket;
  socket.unref = () => socket;
  socket.destroySoon = () => socket.destroy();
  socket.address = () => ({ address: '0.0.0.0', family: 'IPv4', port: 0 });
  socket.remoteAddress = '0.0.0.0';
  socket.remotePort = 0;
  socket.connecting = false;
  return socket;
}

/**
 * node's http/https `request`/`get` accept (url), (url, opts), (opts) and any
 * of those plus a callback. Normalising here keeps the interception honest for
 * every call style the suite uses (`https.request({hostname, path, ...})` and
 * `https.request(urlString)` both appear in these specs).
 */
function hostOf(args) {
  const [first, second] = args;
  if (typeof first === 'string' || first instanceof URL) {
    try { return new URL(String(first)).hostname; } catch { return null; }
  }
  if (first && typeof first === 'object') {
    return first.hostname || first.host || (second && typeof second === 'object'
      ? second.hostname || second.host
      : null);
  }
  return null;
}

function guardRequest(originalFn) {
  return function guardedRequest(...args) {
    if (isLoopbackHost(hostOf(args))) return originalFn.apply(this, args);

    // Inject our socket factory into the options object of whichever call
    // style was used. `agent: undefined` is load-bearing and NOT the same as
    // `agent: false`: node treats `false` as "give me a fresh private Agent"
    // (a truthy agent, which then ignores options.createConnection and dials
    // out for real — the first version of this guard shipped that bug), while
    // undefined + a createConnection function is the documented no-agent path
    // where options.createConnection is actually used.
    const patch = { agent: undefined, createConnection: createBlackHoleSocket };
    const [first, second, third] = args;
    if (first && typeof first === 'object' && !(first instanceof URL)) {
      return originalFn.call(this, Object.assign({}, first, patch), second, third);
    }
    if (second && typeof second === 'object') {
      return originalFn.call(this, first, Object.assign({}, second, patch), third);
    }
    // (url) or (url, cb): promote the callback into the options slot's place.
    return originalFn.call(this, first, patch, second);
  };
}

http.request = guardRequest(http.request);
https.request = guardRequest(https.request);
http.get = guardRequest(http.get);
https.get = guardRequest(https.get);

const NEVER_SETTLES = new Promise(() => {});
const realFetch = globalThis.fetch;
if (typeof realFetch === 'function') {
  globalThis.fetch = function guardedFetch(input, init) {
    const url = typeof input === 'string' || input instanceof URL
      ? String(input)
      : (input && input.url) || '';
    let host = null;
    try { host = new URL(url).hostname; } catch { /* relative/opaque — block */ }
    if (isLoopbackHost(host)) return realFetch.call(this, input, init);
    return NEVER_SETTLES;
  };
}

process.env.E2E_SMOKE_EGRESS_GUARD = '1';
