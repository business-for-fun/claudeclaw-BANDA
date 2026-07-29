#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# lint-bug-cards.sh — R4G card hygiene check (WORKFLOW.md step [6])
#
# Finds cards whose lifecycle lags reality:
#   • verdict "DEPLOY OK" present but Status still open  → status lag
#   • no **Status:** line at all                         → malformed card
#
# Usage: bash scripts/lint-bug-cards.sh
# Exit:  0 = clean, 1 = warnings found
# ─────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUGS_DIR="$SCRIPT_DIR/../projects/r4g/bugs"

# Cards older than V2 (2026-07-28) are legacy backlog — counted, not linted.
# Their cleanup is a separate planned task, not daily noise.
V2_CUTOFF=20260728

WARN=0
LEGACY=0
OUT=""

for f in "$BUGS_DIR"/BUG-*.md "$BUGS_DIR"/TASK-*.md; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  card_date="$(echo "$base" | grep -oP '20\d{6}' | head -1 || echo 0)"
  if [ "$card_date" -lt "$V2_CUTOFF" ]; then
    LEGACY=$((LEGACY+1)); continue
  fi
  status="$(grep -m1 -oP '^\*\*Status:\*\*\s*\K\S+' "$f" 2>/dev/null || true)"

  if [ -z "$status" ]; then
    OUT+="❓ $base: нет строки **Status:**"$'\n'; WARN=1; continue
  fi

  if grep -qE 'DEPLOY OK' "$f" && [[ "$status" =~ ^(open|Open|OPEN|in-progress|in_progress)$ ]]; then
    OUT+="⚠️ $base: вердикт DEPLOY OK, но Status: $status — обнови статус (шаг [6])"$'\n'; WARN=1
  fi
done

if [ "$WARN" -eq 0 ]; then
  echo "📋 Cards: lifecycle in order (legacy pre-V2 skipped: $LEGACY)"
else
  echo "📋 Card hygiene warnings (legacy pre-V2 skipped: $LEGACY):"
  printf '%s' "$OUT"
fi
exit $WARN
