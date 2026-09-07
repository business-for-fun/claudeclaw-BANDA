#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# test-smoke-e2e-specs.sh — negative test for smoke-e2e-specs.sh
# (BUG-20260805-006 Part 3).
#
# Why this exists: smoke-e2e-specs.sh exists specifically to catch files
# that silently stop starting (the exact class of break BUG-20260805-006
# was — 12 files broken for 6 days, nothing ever ran them). A checker that
# has only ever been run against currently-healthy files proves nothing
# about whether it actually DETECTS a broken one — that's the untested half
# of the tool. This script is that half: it feeds smoke-e2e-specs.sh two
# known-good fixtures and two known-broken fixtures in a disposable temp
# dir (via the E2E_DIR override) and asserts the verdict matches for each,
# individually — not just "overall exit code is 1", which would pass even
# if the checker flagged the wrong file for the wrong reason.
#
# Fixtures:
#   good-fast.spec.js        — clean immediate exit 0 (pure-algorithm style,
#                               e.g. mlChainPricingBUG004) → must NOT be flagged
#   good-longrunning.spec.js — stays alive past STARTUP_TIMEOUT without
#                               crashing (browser-driving style) → must NOT
#                               be flagged (killed by our own timeout = OK)
#   bad-syntax.spec.js       — invalid JS syntax → must be flagged, caught by
#                               the `node --check` step (Step 1)
#   bad-require.spec.js      — valid syntax, throws on a missing require()
#                               within milliseconds → must be flagged, caught
#                               by the live-start step (Step 2, fast crash)
#
# Usage: bash scripts/test-smoke-e2e-specs.sh
# Exit:  0 = smoke-e2e-specs.sh classified all four fixtures correctly
#        1 = at least one misclassification (checker is broken)
# ─────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="$(mktemp -d /tmp/smoke-e2e-selftest.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

cat > "$FIXTURE_DIR/good-fast.spec.js" <<'EOF'
// negative-test fixture: clean fast finish — must NOT be flagged
process.exit(0);
EOF

cat > "$FIXTURE_DIR/good-longrunning.spec.js" <<'EOF'
// negative-test fixture: stays alive past the smoke checker's own
// STARTUP_TIMEOUT without crashing — must NOT be flagged (killed by the
// checker's own timeout = classified as "started fine").
setInterval(() => {}, 1000);
EOF

cat > "$FIXTURE_DIR/bad-syntax.spec.js" <<'EOF'
// negative-test fixture: invalid syntax — must be flagged by `node --check`
const x = ;
EOF

cat > "$FIXTURE_DIR/bad-require.spec.js" <<'EOF'
// negative-test fixture: valid syntax, crashes on a missing module within
// milliseconds — must be flagged by the live-start step (fast crash).
require('this-module-does-not-exist-xyz123');
EOF

# ── BUG-20260808-001 fixtures — the prod-config write guard ──────────────
# The guard's whole value is that it stops step 2 BEFORE the file runs. A
# fixture that merely looks like a writer is not enough to prove that: it has
# to be a file which, if started, would leave a mark. Each of these two writes
# a sentinel file on its first line — if the sentinel appears, the guard let it
# run, and the guard is broken no matter what the verdict text says.

cat > "$FIXTURE_DIR/marked-writer.spec.js" <<EOF
// negative-test fixture: a MARKED prod-config writer. Must NOT be started and
// must NOT be flagged — this is the sanctioned opt-out.
// @e2e-smoke-skip-live-start: writes broker-config in its pre-flight
require('fs').writeFileSync('$FIXTURE_DIR/RAN-marked', 'x');
const BROKER_CONFIG_API = 'https://r4g.business-for-fun.com/webhook/r4g/broker-config';
async function apiPost(url, body) { return { url, body }; }
apiPost(BROKER_CONFIG_API, { brokerSettings: { '01': { allowInternalNetting: false } } });
setInterval(() => {}, 1000);
EOF

cat > "$FIXTURE_DIR/unmarked-writer.spec.js" <<EOF
// negative-test fixture: an UNMARKED prod-config writer, built the way half the
// real suite builds its URL — from a base constant, not a literal. Must be
// flagged AND must not be started.
require('fs').writeFileSync('$FIXTURE_DIR/RAN-unmarked', 'x');
const N8N_BASE = 'https://r4g.business-for-fun.com/webhook/r4g';
const BROKER_CONFIG_API = \`\${N8N_BASE}/broker-config\`;
async function apiPost(url, body) { return { url, body }; }
apiPost(BROKER_CONFIG_API, { brokerSettings: { '01': { allowInternalNetting: false } } });
setInterval(() => {}, 1000);
EOF

cat > "$FIXTURE_DIR/config-reader.spec.js" <<EOF
// negative-test fixture: mentions broker-config but only READS it and mocks it
// in the browser. Must still be started — the guard must not quietly swallow
// coverage for every file that merely names the endpoint.
require('fs').writeFileSync('$FIXTURE_DIR/RAN-reader', 'x');
const BROKER_CONFIG_API = 'https://r4g.business-for-fun.com/webhook/r4g/broker-config';
const page = { route: async () => {} };
page.route('**/webhook/r4g/broker-config**', () => {});
async function apiGet(url) { return url; }
apiGet(BROKER_CONFIG_API);
setInterval(() => {}, 1000);
EOF

# ── BUG-20260907-001 fixtures — identity/auth mutators + the egress guard ────
# The 08-08 guard asked "does this file post to broker-config?" and let two
# specs through that instead created real people and mailed real magic links
# every night for weeks. So there are two new fixture families here: one for
# the widened static deny-list (identity/auth mutating actions), and one for
# the runtime egress guard, which is the layer that no longer depends on
# anyone predicting the next dangerous endpoint.

cat > "$FIXTURE_DIR/marked-identity-writer.spec.js" <<EOF
// negative-test fixture: a MARKED identity mutator. Must NOT be started, must
// NOT be flagged — the sanctioned opt-out, same as marked-writer above.
// @e2e-smoke-skip-live-start: real person_create against production
require('fs').writeFileSync('$FIXTURE_DIR/RAN-marked-identity', 'x');
async function apiPost(url, body) { return { url, body }; }
apiPost('https://r4g.business-for-fun.com/webhook/r4g/identity', { action: 'person_create', email: 'x@y.z' });
setInterval(() => {}, 1000);
EOF

cat > "$FIXTURE_DIR/unmarked-identity-writer.spec.js" <<EOF
// negative-test fixture: an UNMARKED identity mutator — the exact shape of
// identityMismatchBUG20260814004.spec.js, which the broker-config-only guard
// happily started every night (BUG-20260907-001). Must be flagged AND must not
// be started.
require('fs').writeFileSync('$FIXTURE_DIR/RAN-unmarked-identity', 'x');
const N8N_BASE = 'https://r4g.business-for-fun.com/webhook/r4g';
async function apiPost(url, body) { return { url, body }; }
apiPost(\`\${N8N_BASE}/identity\`, { action: 'person_create', email: 'x@y.z' });
apiPost(\`\${N8N_BASE}/auth\`, { action: 'link_request', email: 'x@y.z' });
setInterval(() => {}, 1000);
EOF

cat > "$FIXTURE_DIR/prose-mentions-mutation.spec.js" <<EOF
// negative-test fixture: talks ABOUT person_update and account_purge in prose,
// the way nine real specs in this suite do, but never calls them. Must still be
// started — an over-eager keyword match here would silently strip live-start
// coverage from a third of the suite.
require('fs').writeFileSync('$FIXTURE_DIR/RAN-prose', 'x');
// The row flips to Reactivate after the person_update request; account_purge
// is Olaf's tool, not ours.
setInterval(() => {}, 1000);
EOF

cat > "$FIXTURE_DIR/egress-node-http.spec.js" <<EOF
// negative-test fixture for the runtime egress guard. Fires a node-side HTTPS
// request at a host that CANNOT resolve (.invalid is reserved by RFC 2606), in
// both call styles the suite uses. Unguarded, DNS fails within milliseconds and
// the 'error' handler leaves a sentinel. Guarded, the request is handed a black
// hole: no response, no error, no sentinel — which is exactly the "still alive
// at kill time" behaviour the checker must classify as a healthy start.
const fs = require('fs');
const https = require('https');
fs.writeFileSync('$FIXTURE_DIR/RAN-egress-http', 'x');
if (process.env.E2E_SMOKE_EGRESS_GUARD === '1') fs.writeFileSync('$FIXTURE_DIR/GUARD-ENV', 'x');
const mark = tag => { try { fs.writeFileSync('$FIXTURE_DIR/EGRESS-' + tag, 'x'); } catch (e) {} };
const a = https.request({ hostname: 'nope.example.invalid', path: '/', method: 'POST' }, () => mark('http-response'));
a.on('error', () => mark('http-error'));
a.end('{}');
const b = https.get('https://nope.example.invalid/', () => mark('url-response'));
b.on('error', () => mark('url-error'));
setInterval(() => {}, 1000);
EOF

cat > "$FIXTURE_DIR/egress-fetch.spec.js" <<EOF
// negative-test fixture: same idea, through global fetch() — a separate stack
// (undici), so a guard that only patches http/https would pass the fixture
// above and still let this one out.
const fs = require('fs');
fs.writeFileSync('$FIXTURE_DIR/RAN-egress-fetch', 'x');
const mark = tag => { try { fs.writeFileSync('$FIXTURE_DIR/EGRESS-' + tag, 'x'); } catch (e) {} };
fetch('https://nope.example.invalid/', { method: 'POST' })
  .then(() => mark('fetch-resolved'))
  .catch(() => mark('fetch-rejected'));
setInterval(() => {}, 1000);
EOF

cat > "$FIXTURE_DIR/egress-loopback.spec.js" <<EOF
// negative-test fixture: the guard must NOT be a blanket kill switch on the
// network. Loopback stays open (nothing on production answers at 127.0.0.1),
// so a spec's own local fixture server keeps working. Sentinel is written by
// the server on receipt — proof the request actually arrived, not just that no
// error was raised.
const fs = require('fs');
const http = require('http');
fs.writeFileSync('$FIXTURE_DIR/RAN-egress-loopback', 'x');
const srv = http.createServer((req, res) => {
  fs.writeFileSync('$FIXTURE_DIR/EGRESS-loopback-arrived', 'x');
  res.end('ok');
});
srv.listen(0, '127.0.0.1', () => {
  http.get({ hostname: '127.0.0.1', port: srv.address().port, path: '/' }, r => r.resume());
});
setInterval(() => {}, 1000);
EOF

RUN_OUT="$(E2E_DIR="$FIXTURE_DIR" bash "$SCRIPT_DIR/smoke-e2e-specs.sh" 2>&1)"
RUN_EXIT=$?

FAIL=0

assert_flagged() {
  local file="$1"
  if echo "$RUN_OUT" | grep -q "❌ $file:"; then
    echo "  ✅ $file correctly flagged"
  else
    echo "  ❌ $file NOT flagged — checker missed a broken fixture"
    FAIL=1
  fi
}

assert_not_flagged() {
  local file="$1"
  if echo "$RUN_OUT" | grep -q "❌ $file:"; then
    echo "  ❌ $file WRONGLY flagged — false positive on a healthy fixture"
    FAIL=1
  else
    echo "  ✅ $file correctly NOT flagged"
  fi
}

echo "── smoke-e2e-specs.sh self-test (E2E_DIR=$FIXTURE_DIR) ──"
echo "$RUN_OUT"
echo "── verdicts ──"


assert_not_flagged "good-fast.spec.js"
assert_not_flagged "good-longrunning.spec.js"
assert_flagged "bad-syntax.spec.js"
assert_flagged "bad-require.spec.js"

# ── BUG-20260808-001 verdicts ────────────────────────────────────────────
assert_not_started() {
  local file="$1" sentinel="$2"
  if [ -e "$FIXTURE_DIR/$sentinel" ]; then
    echo "  ❌ $file WAS STARTED — the prod-config guard did not stop step 2"
    FAIL=1
  else
    echo "  ✅ $file never started (guard held)"
  fi
}

assert_started() {
  local file="$1" sentinel="$2"
  if [ -e "$FIXTURE_DIR/$sentinel" ]; then
    echo "  ✅ $file started (guard did not over-reach)"
  else
    echo "  ❌ $file NOT started — guard is swallowing healthy files"
    FAIL=1
  fi
}

assert_reported_skipped() {
  local file="$1"
  if echo "$RUN_OUT" | grep -q "$file"; then
    echo "  ✅ $file named in the output (no silent skip)"
  else
    echo "  ❌ $file skipped SILENTLY — a skip nobody sees reads as coverage"
    FAIL=1
  fi
}

assert_not_flagged   "marked-writer.spec.js"
assert_not_started   "marked-writer.spec.js"   "RAN-marked"
assert_reported_skipped "marked-writer.spec.js"

assert_flagged       "unmarked-writer.spec.js"
assert_not_started   "unmarked-writer.spec.js" "RAN-unmarked"

assert_not_flagged   "config-reader.spec.js"
assert_started       "config-reader.spec.js"    "RAN-reader"

# ── BUG-20260907-001 verdicts: widened static deny-list ──────────────────
assert_not_flagged   "marked-identity-writer.spec.js"
assert_not_started   "marked-identity-writer.spec.js"   "RAN-marked-identity"
assert_reported_skipped "marked-identity-writer.spec.js"

assert_flagged       "unmarked-identity-writer.spec.js"
assert_not_started   "unmarked-identity-writer.spec.js" "RAN-unmarked-identity"

assert_not_flagged   "prose-mentions-mutation.spec.js"
assert_started       "prose-mentions-mutation.spec.js"  "RAN-prose"

# ── BUG-20260907-001 verdicts: the runtime egress guard ──────────────────
# Each of these is asserted in two halves on purpose: the fixture DID run
# (so the absence below means "blocked", not "never executed"), and the
# egress sentinel is absent.
assert_no_sentinel() {
  local what="$1" sentinel="$2"
  if [ -e "$FIXTURE_DIR/$sentinel" ]; then
    echo "  ❌ $what — egress guard did NOT intercept (sentinel $sentinel present)"
    FAIL=1
  else
    echo "  ✅ $what — no egress (guard held)"
  fi
}

assert_started "egress-node-http.spec.js" "RAN-egress-http"
if [ -e "$FIXTURE_DIR/GUARD-ENV" ]; then
  echo "  ✅ egress guard was actually preloaded into the live start"
else
  echo "  ❌ egress guard NOT preloaded — every 'no egress' verdict below is vacuous"
  FAIL=1
fi
assert_no_sentinel "node https.request(options)" "EGRESS-http-error"
assert_no_sentinel "node https.request(options)" "EGRESS-http-response"
assert_no_sentinel "node https.get(url)"         "EGRESS-url-error"
assert_no_sentinel "node https.get(url)"         "EGRESS-url-response"

assert_started "egress-fetch.spec.js" "RAN-egress-fetch"
assert_no_sentinel "global fetch()" "EGRESS-fetch-resolved"
assert_no_sentinel "global fetch()" "EGRESS-fetch-rejected"

assert_started "egress-loopback.spec.js" "RAN-egress-loopback"
assert_started "loopback request (must stay allowed)" "EGRESS-loopback-arrived"


if [ "$RUN_EXIT" -ne 1 ]; then
  echo "  ❌ overall exit code was $RUN_EXIT, expected 1 (fixture dir has broken files)"
  FAIL=1
else
  echo "  ✅ overall exit code 1, as expected"
fi

# ── BUG-20260907-001: fail-closed pass ───────────────────────────────────
# A guard that can be silently absent is not a guard. Second run, same
# fixtures, egress guard pointed at a path that does not exist: nothing may be
# started at all, and the run must go red rather than quietly fall back to the
# unguarded live start that caused this card.
echo "── fail-closed pass (egress guard missing) ──"
FAILCLOSED_DIR="$(mktemp -d /tmp/smoke-e2e-failclosed.XXXXXX)"
cat > "$FAILCLOSED_DIR/plain-longrunning.spec.js" <<EOF
// A perfectly innocent spec: no marker, no prod write. Even this one must not
// be started while the egress guard is unavailable.
require('fs').writeFileSync('$FAILCLOSED_DIR/RAN-plain', 'x');
setInterval(() => {}, 1000);
EOF

FC_OUT="$(E2E_DIR="$FAILCLOSED_DIR" \
  E2E_SMOKE_EGRESS_GUARD_PATH="$FAILCLOSED_DIR/does-not-exist.cjs" \
  bash "$SCRIPT_DIR/smoke-e2e-specs.sh" 2>&1)"
FC_EXIT=$?

if [ -e "$FAILCLOSED_DIR/RAN-plain" ]; then
  echo "  ❌ a spec was STARTED with no egress guard present — fail-closed branch is broken"
  FAIL=1
else
  echo "  ✅ nothing started while the guard was missing"
fi
if echo "$FC_OUT" | grep -q "egress guard missing"; then
  echo "  ✅ missing guard reported explicitly"
else
  echo "  ❌ missing guard NOT reported — a silent unguarded-or-not run is the whole failure mode"
  FAIL=1
fi
if [ "$FC_EXIT" -eq 1 ]; then
  echo "  ✅ fail-closed run exits 1"
else
  echo "  ❌ fail-closed run exited $FC_EXIT, expected 1"
  FAIL=1
fi
rm -rf "$FAILCLOSED_DIR"

if [ "$FAIL" -eq 0 ]; then
  echo "✅ smoke-e2e-specs.sh negative test PASSED — checker detects broken files, not just green ones"
else
  echo "❌ smoke-e2e-specs.sh negative test FAILED — see verdicts above"
fi

exit $FAIL
