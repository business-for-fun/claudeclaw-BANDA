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
