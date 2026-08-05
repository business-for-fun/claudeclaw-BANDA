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
# Checks every *.spec.js that actually drives a browser (require/import of
# `playwright` or `@playwright/test`) for evidence of Rule 12 protection —
# ANY of:
#   1. references fixtures/isolated-page(.js) — the standard path (installs
#      installIsolationGuard(); most files use this).
#   2. carries an explicit, commented opt-out: `GUARD-EXEMPT: <reason>` — the
#      reviewed exception for a file that predates the shared guard and
#      keeps its own Rule-12-compliant mock (e.g. iNetLogFEAT20260801003.spec.js,
#      whose own route() already handles broker-config correctly and would
#      be SHADOWED, not helped, by also calling installIsolationGuard — see
#      memory_chunk e1cfb3ff for why). Added by hand only after actually
#      reading that file's route() handler and confirming it absorbs every
#      non-GET to every guarded endpoint — six files carry this today.
#   3. is listed in e2e-guard-baseline.txt — KNOWN, un-reviewed, pre-existing
#      debt frozen 2026-08-05 (40 files). Deliberately NOT auto-passed by
#      "has some .route() call somewhere" — an earlier version of this
#      script did exactly that and it's a false sense of security: EVERY
#      ONE of those 40 files has at least one .route() call (confirmed by
#      grep during this task), but plenty are for mocking unrelated
#      endpoints (ml-state, ml-accept, ...) while leaving broker-config
#      completely unmocked. "Some route() exists" is not "broker-config is
#      covered." Baselining is a conscious, visible acknowledgment of debt,
#      not silent clearance — clearing a line requires actually reviewing
#      that file's route() coverage (or migrating it to the shared fixture)
#      and removing the line in the same commit.
# A file matching NONE of the three is flagged as a NEW violation — this is
# the actual regression class the task exists to catch.
#
# Separately, ANY *.spec.js (whether or not it drives a browser) that
# imports `@playwright/test` directly is flagged unconditionally — these
# files use the raw `playwright` library plus fixtures/isolated-page.js by
# convention; switching to the @playwright/test runner style is a different
# execution model that bypasses the guard fixture entirely and needs review,
# not a silent merge. (No current file does this — tripwire for a scenario
# that hasn't happened yet, matching the card's own literal wording.)
#
# Usage: bash scripts/lint-e2e-guard-imports.sh
# Exit:  0 = clean, 1 = violations found
# ─────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
E2E_DIR="$SCRIPT_DIR/../projects/r4g/frontend/__tests__/e2e"
BASELINE_FILE="$SCRIPT_DIR/e2e-guard-baseline.txt"

VIOLATIONS=0
OUT=""
CHECKED=0
BASELINE_COUNT=0
NEW_VIOLATION_COUNT=0

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
    NEW_VIOLATION_COUNT=$((NEW_VIOLATION_COUNT+1))
  fi

  # Only files that actually drive a browser (raw `playwright` — the pattern
  # every current spec uses — or @playwright/test) need the guard checks.
  grep -qE "(require\(['\"](playwright|@playwright/test)['\"]\)|from\s+['\"](playwright|@playwright/test)['\"])" "$f" || continue

  # Path 1: shared fixture.
  grep -qE "isolated-page" "$f" && continue

  # Path 2: explicit, reviewed exemption.
  grep -q "GUARD-EXEMPT:" "$f" && continue

  # Path 3: known, acknowledged, pre-existing debt — visible, not silent.
  if [ -f "$BASELINE_FILE" ] && grep -qxF "$base" "$BASELINE_FILE"; then
    BASELINE_COUNT=$((BASELINE_COUNT+1))
    continue
  fi

  OUT+="❌ $base: запускает браузер, но не ссылается на fixtures/isolated-page, нет GUARD-EXEMPT: и файла нет в e2e-guard-baseline.txt — НОВОЕ нарушение, класс риска BUG-20260804-018"$'\n'
  VIOLATIONS=1
  NEW_VIOLATION_COUNT=$((NEW_VIOLATION_COUNT+1))
done

if [ "$VIOLATIONS" -eq 0 ]; then
  echo "✅ e2e guard check: $CHECKED *.spec.js проверены ($BASELINE_COUNT известный pre-existing долг в baseline), 0 новых нарушений"
else
  echo "❌ e2e guard VIOLATIONS — $NEW_VIOLATION_COUNT NEW:"
  printf '%s' "$OUT"
fi

exit $VIOLATIONS
