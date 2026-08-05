#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# lint-e2e-guard-imports.sh — TASK-20260805-001: guard against *.spec.js
# regressing back to zero write-interception (the BUG-20260804-018 class of
# risk that FEAT-20260805-001's shared guard was built to close).
#
# FEAT-20260805-001 added a shared guard for frontend/__tests__/e2e/*.spec.js
# (playwright.spec.config.js + fixtures/isolated-page.js) — but nothing
# stopped a NEW spec file from driving a real browser against the live
# backend without ever calling it, exactly like the two files that caused
# BUG-20260804-018 in the first place. This script is that stop.
#
# Checks every *.spec.js that actually drives a browser (chromium.launch)
# for evidence of Rule 12 protection — ANY of:
#   1. calls installIsolationGuard(...) — the standard path (most files).
#   2. has its own page/context/ctx.route() interception — the reviewed
#      exception for files that predate the shared guard and keep their own
#      Rule-12-compliant mock (e.g. iNetLogFEAT20260801003.spec.js, whose
#      own route() already handles broker-config correctly and would be
#      SHADOWED, not helped, by also calling installIsolationGuard — see
#      memory_chunk e1cfb3ff for why).
#   3. carries an explicit, commented opt-out: `// GUARD-EXEMPT: <reason>`
#      — for a file that genuinely never touches the live backend at all.
# A file matching NONE of the three is flagged: it drives a real browser
# with zero write protection.
#
# Separately, ANY *.spec.js (whether or not it drives a browser) that
# imports `@playwright/test` directly is flagged — these files use the raw
# `playwright` library plus fixtures/isolated-page.js by convention;
# switching to the @playwright/test runner style is a different execution
# model that bypasses the guard fixture entirely and needs review, not a
# silent merge.
#
# Usage: bash scripts/lint-e2e-guard-imports.sh
# Exit:  0 = clean, 1 = violations found
# ─────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
E2E_DIR="$SCRIPT_DIR/../projects/r4g/frontend/__tests__/e2e"

VIOLATIONS=0
OUT=""
CHECKED=0

for f in "$E2E_DIR"/*.spec.js; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  CHECKED=$((CHECKED+1))

  # Check 1: direct @playwright/test import — different execution model,
  # bypasses fixtures/isolated-page.js entirely regardless of what else is
  # in the file. Flag unconditionally, independent of the checks below.
  if grep -qE "from ['\"]@playwright/test['\"]|require\(['\"]@playwright/test['\"]\)" "$f"; then
    OUT+="❌ $base: импортирует @playwright/test напрямую — другая модель выполнения, гарантированно в обход fixtures/isolated-page.js"$'\n'
    VIOLATIONS=1
  fi

  # Only files that actually drive a browser need the interception guard.
  grep -q "chromium.launch(" "$f" || continue

  # Explicit, reviewed exemption.
  grep -q "GUARD-EXEMPT:" "$f" && continue

  HAS_GUARD_CALL=0
  grep -q "installIsolationGuard(" "$f" && HAS_GUARD_CALL=1

  HAS_OWN_ROUTE=0
  grep -qE "\.route\(" "$f" && HAS_OWN_ROUTE=1

  if [ "$HAS_GUARD_CALL" -eq 0 ] && [ "$HAS_OWN_ROUTE" -eq 0 ]; then
    OUT+="❌ $base: запускает браузер (chromium.launch) без installIsolationGuard() и без собственного .route() — не защищён, класс риска BUG-20260804-018"$'\n'
    VIOLATIONS=1
  fi
done

if [ "$VIOLATIONS" -eq 0 ]; then
  echo "✅ e2e guard check: $CHECKED *.spec.js проверены, все браузерные — защищены (installIsolationGuard / собственный route() / явное GUARD-EXEMPT)"
else
  echo -n "$OUT"
fi

exit $VIOLATIONS
