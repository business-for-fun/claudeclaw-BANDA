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


if [ "$RUN_EXIT" -ne 1 ]; then
  echo "  ❌ overall exit code was $RUN_EXIT, expected 1 (fixture dir has broken files)"
  FAIL=1
else
  echo "  ✅ overall exit code 1, as expected"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "✅ smoke-e2e-specs.sh negative test PASSED — checker detects broken files, not just green ones"
else
  echo "❌ smoke-e2e-specs.sh negative test FAILED — see verdicts above"
fi

exit $FAIL
