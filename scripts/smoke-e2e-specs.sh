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
# ── BUG-20260808-001: the live-start step must never write to production ──
#
# On 2026-08-08 at 02:04:51 UTC this script disabled the iNet feature for every
# broker. Step 2 started allowInternalNettingServerSideBUG002.spec.js, whose
# FIRST action is a pre-flight `POST /webhook/r4g/broker-config` setting
# allowInternalNetting=false for brokers 01 and 02 — against the PRODUCTION
# endpoint, hardcoded. Five seconds later we killed the process, long before it
# reached the line that turns the flag back on. The nightly report said
# "✅ 61 *.spec.js все стартуют", which was true and beside the point.
#
# The hole was structural, not a mistake in that spec: this script exists to
# kill processes half-way, so ANY spec whose opening move mutates shared state
# leaves that state mutated. So the rule here is about the runner, not about
# one file:
#
#   A spec that writes to the production broker-config does not get the
#   live-start step. It still gets `node --check`, which is the step that
#   actually catches the break this script was written for (BUG-20260805-006).
#
# Two mechanisms, deliberately separate:
#
#   1. MECHANISM — an explicit marker comment in the spec:
#          @e2e-smoke-skip-live-start: <reason>
#      Exact, self-documenting, no guessing from source text.
#
#   2. SAFETY NET — a conservative pattern match for "posts to the production
#      broker-config". A file that looks like a writer but carries no marker is
#      FLAGGED (the run fails) *and* skipped anyway. Over-eager by design: the
#      cost of a false positive is someone adding one comment line; the cost of
#      a false negative is the incident above, on production, at 02:04 UTC.
#
# Deliberate boundary, stated rather than left implicit: this guards the broker
# CONFIG endpoint only — the flag that decides whether a broker can reach the
# feature at all. Specs that POST rounds to other production endpoints append
# to history rather than revoke access, and are out of scope here; the durable
# answer for all of them is the admin key on the write path (part 2 of this
# card), not a longer regex.
#
# Usage: bash scripts/smoke-e2e-specs.sh
# Exit:  0 = every file starts cleanly, 1 = at least one failed to start, or a
#            prod-config writer is missing its marker
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

# BUG-20260808-001 — see header. The marker a spec uses to opt out of step 2.
SKIP_MARKER='@e2e-smoke-skip-live-start'
# Safety net: the broker-config endpoint, and a Node-side POST to it. Both must
# be present for a file to look like a writer. Browser-side mocks
# (`page.route`) and baseline GETs match the first pattern but not the second,
# which is why the two are separate conditions rather than one.
#
# The endpoint is matched by PATH, not by the full production URL, and that is
# load-bearing: only 7 of the 14 specs that talk to this endpoint spell the URL
# out. The other half build it as `${N8N_BASE}/broker-config`, and N8N_BASE is
# 'https://r4g.business-for-fun.com/webhook/r4g' in every one of them. A regex
# anchored on the literal URL passes those files straight through to step 2 —
# which is the very failure this guard exists to prevent.
CONFIG_PATH_RE='broker-config'
# Call sites, not helper definitions: every one of these helpers is generic, so
# the danger is in what it is CALLED with. The helper names are the ones this
# suite actually defines (apiPost/postJson/postToBackend/postNetting); an
# unknown future helper is the known gap, and the durable answer to it is the
# admin key on the write path (part 2 of this card), not a longer list.
CONFIG_WRITE_RE='(apiPost|postJson|postToBackend|postNetting|httpPost)[[:space:]]*\([[:space:]]*[A-Za-z_]*CONFIG[A-Za-z_]*|(apiPost|postJson|postToBackend|postNetting|httpPost)[[:space:]]*\([[:space:]]*.[^,]*broker-config'

FAIL=0
OUT=""
CHECKED=0
SKIPPED_LIVE=0
SKIPPED_NOTE=""
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

  # ── Step 1b: may this file be STARTED at all? (BUG-20260808-001) ────
  # Runs after `node --check`, so a prod-config writer still gets the check
  # that matters most, and before anything is executed, so the answer cannot
  # arrive too late.
  HAS_MARKER=0
  grep -qF "$SKIP_MARKER" "$f" && HAS_MARKER=1

  LOOKS_LIKE_WRITER=0
  if grep -qE "$CONFIG_PATH_RE" "$f" && grep -qE "$CONFIG_WRITE_RE" "$f"; then
    LOOKS_LIKE_WRITER=1
  fi

  if [ "$HAS_MARKER" -eq 1 ] || [ "$LOOKS_LIKE_WRITER" -eq 1 ]; then
    # Skip the live start either way — including the unmarked case, so a
    # forgotten marker costs a red build, never a production write.
    SKIPPED_LIVE=$((SKIPPED_LIVE + 1))
    if [ "$HAS_MARKER" -eq 1 ]; then
      REASON="$(grep -oE "$SKIP_MARKER:?[[:space:]]*.*" "$f" | head -1 | sed "s/$SKIP_MARKER:\?[[:space:]]*//")"
      SKIPPED_NOTE+="   · $base — live start skipped: ${REASON:-marked, no reason given}"$'\n'
    else
      OUT+="❌ $base: posts to the PRODUCTION broker-config but carries no $SKIP_MARKER marker. "
      OUT+="Add the marker (with a reason) or stop the spec writing to production — see BUG-20260808-001."$'\n'
      SKIPPED_NOTE+="   · $base — live start skipped (unmarked writer, flagged above)"$'\n'
      FAIL=1
    fi
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
  echo "✅ e2e startup smoke: $CHECKED *.spec.js проверены, $((CHECKED - SKIPPED_LIVE)) запущены — все стартуют"
else
  echo "❌ e2e startup smoke — FAILURES:"
  printf '%s' "$OUT"
fi

# Never let a skip pass as coverage. A silent exclusion reads as "we ran
# everything" — which is exactly how the nightly reported success on the night
# it broke production (BUG-20260808-001).
if [ "$SKIPPED_LIVE" -gt 0 ]; then
  echo "ℹ️  live-start step skipped for $SKIPPED_LIVE of $CHECKED file(s) — node --check still applied:"
  printf '%s' "$SKIPPED_NOTE"
fi

exit $FAIL
