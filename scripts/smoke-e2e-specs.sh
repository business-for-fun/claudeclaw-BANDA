#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# smoke-e2e-specs.sh — BUG-20260805-006 Part 3: cheap "does it at least
# start" check for every frontend/__tests__/e2e/*.spec.js.
#
# Why this exists: BUG-20260805-006 was a module-loading break (top-level
# ES `import` vs `__tests__/e2e/package.json` `"type":"commonjs"`) that hit
# 12 files silently on 2026-07-30 and stayed uncaught for 6 days — nothing
# in the nightly run ever tried to actually EXECUTE these files, only the
# Jest unit suite (a completely separate tree). lint-e2e-guard-imports.sh
# (TASK-20260805-001) checks these files for TEXT patterns (does it
# reference the guard fixture) but never runs them either — it would not
# have caught this class of break. This script closes that gap.
#
# NOT a full scenario run — each real E2E scenario takes 60-170s and drives
# a live browser against dev.r4g.business-for-fun.com. This check only
# proves the file's module loads and the process begins executing without
# an immediate crash (require/import error, syntax mismatch, missing
# dependency) — cheap, capped per file, safe to run every night alongside
# the existing checks.
#
# Method, per file:
#   1. `node --check` — catches syntax/module-system errors instantly, no
#      process spawn, no network. This alone would have caught
#      BUG-20260805-006 the same day it broke.
#   2. A short timeout run (kills the process after STARTUP_TIMEOUT seconds
#      regardless of progress). Classification:
#        - killed by our own timeout after running the full window  → OK
#          (started fine, full scenarios legitimately take much longer than
#          our short window — we only care that it was still alive)
#        - clean fast exit 0                                        → OK
#          (pure-algorithm specs like mlChainPricingBUG004 finish in
#          seconds, no browser needed)
#        - non-zero exit WITHIN THE FIRST FEW SECONDS (before chromium
#          launch + goto could plausibly have even started)          → FLAG
#          (this is the "didn't start" signal — require() blew up, a
#          dependency is missing, syntax broke again, etc.)
#        - non-zero exit later than that but before the timeout       → NOT
#          flagged here on purpose. That's a real functional test result
#          (a scenario assertion failed), not a startup failure — separate
#          concern, covered by Kim's per-card verification and manual runs,
#          not this cheap smoke check.
#
# Usage: bash scripts/smoke-e2e-specs.sh
# Exit:  0 = every file starts cleanly, 1 = at least one failed to start
# ─────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# E2E_DIR override exists for test-smoke-e2e-specs.sh (negative-test harness)
# to point this script at a disposable fixture dir instead of the real e2e
# suite. Not meant to be set in normal/nightly usage.
E2E_DIR="${E2E_DIR:-$SCRIPT_DIR/../projects/r4g/frontend/__tests__/e2e}"
export NODE_PATH="${NODE_PATH:-/usr/lib/node_modules}"

STARTUP_TIMEOUT=5     # seconds — window we let each process run before killing it
CRASH_THRESHOLD_MS=3000  # a non-zero exit before this is "didn't start", not "test failed"

FAIL=0
OUT=""
CHECKED=0
TMP_ERR="/tmp/smoke-e2e-check-err.$$"
TMP_RUN="/tmp/smoke-e2e-run-out.$$"
trap 'rm -f "$TMP_ERR" "$TMP_RUN"' EXIT

for f in "$E2E_DIR"/*.spec.js; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  CHECKED=$((CHECKED + 1))

  # ── Step 1: static check ──────────────────────────────────────────
  if ! node --check "$f" 2>"$TMP_ERR"; then
    OUT+="❌ $base: node --check FAILED — $(head -1 "$TMP_ERR")"$'\n'
    FAIL=1
    continue
  fi

  # ── Step 2: short live-start check ──────────────────────────────────
  START_NS=$(date +%s%N)
  timeout -s KILL "$STARTUP_TIMEOUT" node "$f" >"$TMP_RUN" 2>&1
  CODE=$?
  END_NS=$(date +%s%N)
  ELAPSED_MS=$(((END_NS - START_NS) / 1000000))

  if [ "$CODE" -eq 137 ] && [ "$ELAPSED_MS" -ge $((STARTUP_TIMEOUT * 1000 - 500)) ]; then
    : # ran the full window before we killed it — started fine
  elif [ "$CODE" -eq 0 ]; then
    : # fast clean finish — started (and finished) fine
  elif [ "$ELAPSED_MS" -lt "$CRASH_THRESHOLD_MS" ]; then
    ERRLINE="$(grep -m1 -E 'Error|Cannot find module|SyntaxError' "$TMP_RUN" || tail -1 "$TMP_RUN")"
    OUT+="❌ $base: crashed ${ELAPSED_MS}ms after start (exit $CODE) — $ERRLINE"$'\n'
    FAIL=1
  fi
  # else: non-zero exit after CRASH_THRESHOLD_MS but before the timeout —
  # a real scenario assertion failed, not a startup problem. Not this
  # script's job — intentionally not flagged.
done

if [ "$FAIL" -eq 0 ]; then
  echo "✅ e2e startup smoke: $CHECKED *.spec.js все стартуют"
else
  echo "❌ e2e startup smoke — FAILURES:"
  printf '%s' "$OUT"
fi

exit $FAIL
