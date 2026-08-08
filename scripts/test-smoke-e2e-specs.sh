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

# ── BUG-20260808-001 fixtures ────────────────────────────────────────────
# The live-start step must refuse to START a spec that writes to the
# production broker-config. Both halves of that rule are tested: the marked
# file must be skipped SILENTLY-BUT-REPORTED (not flagged as broken), and the
# unmarked one must be flagged AND skipped. The marker check has to beat the
# crash check, so both fixtures also crash instantly — if the runner started
# them, the fast-crash classifier would flag them and the assertions below
# would tell us apart from a real skip.

cat > "$FIXTURE_DIR/marked-prod-writer.spec.js" <<'EOF'
// negative-test fixture: writes to the production broker-config AND carries
// the opt-out marker — must be skipped, must NOT be flagged.
// @e2e-smoke-skip-live-start: pre-flight POST would disable the feature
const BROKER_CONFIG_API = 'https://r4g.business-for-fun.com/webhook/r4g/broker-config';
async function apiPost() {}
apiPost(BROKER_CONFIG_API, { brokerSettings: { '01': { allowInternalNetting: false } } });
throw new Error('this fixture must never be executed by the smoke runner');
EOF

cat > "$FIXTURE_DIR/unmarked-prod-writer.spec.js" <<'EOF'
// negative-test fixture: writes to the production broker-config and FORGOT
// the marker — must be flagged (red build) and still not executed.
const BROKER_CONFIG_API = 'https://r4g.business-for-fun.com/webhook/r4g/broker-config';
async function apiPost() {}
apiPost(BROKER_CONFIG_API, { brokerSettings: { '01': { allowInternalNetting: false } } });
throw new Error('this fixture must never be executed by the smoke runner');
EOF

cat > "$FIXTURE_DIR/good-config-reader.spec.js" <<'EOF'
// negative-test fixture: mentions the production broker-config but only READS
// it (baseline snapshot) — must keep its live-start step, must NOT be skipped.
// Guards against the safety net becoming so eager it excludes half the suite.
const BROKER_CONFIG_API = 'https://r4g.business-for-fun.com/webhook/r4g/broker-config';
async function apiGet() {}
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
assert_skipped_live() {
  local file="$1"
  if echo "$RUN_OUT" | grep -q "· $file — live start skipped"; then
    echo "  ✅ $file live start correctly skipped (and reported, not silent)"
  else
    echo "  ❌ $file was NOT skipped — the runner would write to production"
    FAIL=1
  fi
}

assert_not_skipped_live() {
  local file="$1"
  if echo "$RUN_OUT" | grep -q "· $file — live start skipped"; then
    echo "  ❌ $file WRONGLY skipped — the safety net is eating healthy coverage"
    FAIL=1
  else
    echo "  ✅ $file kept its live-start step"
  fi
}

assert_not_flagged "good-fast.spec.js"
assert_not_flagged "good-longrunning.spec.js"
assert_flagged "bad-syntax.spec.js"
assert_flagged "bad-require.spec.js"

# BUG-20260808-001 — the prod-config rule, both halves plus its boundary.
assert_skipped_live     "marked-prod-writer.spec.js"
assert_not_flagged      "marked-prod-writer.spec.js"
assert_skipped_live     "unmarked-prod-writer.spec.js"
assert_flagged          "unmarked-prod-writer.spec.js"
assert_not_skipped_live "good-config-reader.spec.js"
assert_not_flagged      "good-config-reader.spec.js"

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
