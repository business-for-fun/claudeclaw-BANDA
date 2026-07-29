#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# R4G Nightly Test Runner
# Runs Jest test suite + n8n sync check (verify-n8n.sh, Rule 10),
# saves results, notifies via Telegram in ONE morning message.
#
# Usage: bash scripts/run-r4g-tests.sh
# Cron:  0 2 * * * (daily at 02:00 UTC)
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Load environment ────────────────────────────────────────────
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -a
  source "$PROJECT_ROOT/.env"
  set +a
fi

# All notifications via main ClaudeClaw bot
BOT_TOKEN="$TELEGRAM_BOT_TOKEN"

# ── Paths ───────────────────────────────────────────────────────
FRONTEND_DIR="$PROJECT_ROOT/projects/r4g/frontend"
RESULTS_DIR="$PROJECT_ROOT/projects/test-results"
DATE_STAMP="$(date -u +%Y-%m-%d)"
RESULT_FILE="$RESULTS_DIR/r4g-jest-${DATE_STAMP}.txt"

# ── Ensure output directory exists ──────────────────────────────
mkdir -p "$RESULTS_DIR"

# ── Run tests ───────────────────────────────────────────────────
echo "[$DATE_STAMP] Running R4G Jest tests..."

cd "$FRONTEND_DIR"

TEST_EXIT=0
TEST_OUTPUT="$(npm test -- --ci --forceExit 2>&1)" || TEST_EXIT=$?

# Save full output
echo "$TEST_OUTPUT" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "Exit code: $TEST_EXIT" >> "$RESULT_FILE"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RESULT_FILE"

# ── Parse results ───────────────────────────────────────────────
# Extract summary line: "Tests: X passed, Y total" or "Tests: X failed, Y passed, Z total"
SUMMARY_LINE="$(echo "$TEST_OUTPUT" | grep -E '^Tests:' | tail -1 || echo '')"
SUITES_LINE="$(echo "$TEST_OUTPUT" | grep -E '^Test Suites:' | tail -1 || echo '')"
TIME_LINE="$(echo "$TEST_OUTPUT" | grep -E '^Time:' | tail -1 || echo '')"

# Count passed/failed from summary
TESTS_PASSED="$(echo "$SUMMARY_LINE" | grep -oP '\d+ passed' | grep -oP '\d+' || echo '0')"
TESTS_FAILED="$(echo "$SUMMARY_LINE" | grep -oP '\d+ failed' | grep -oP '\d+' || echo '0')"
TESTS_TOTAL="$(echo "$SUMMARY_LINE" | grep -oP '\d+ total' | grep -oP '\d+' || echo '0')"

# ── n8n sync check (Rule 10: live nodes == repo files) ──────────
# --quiet: no separate Telegram alert — the report joins THIS message.
VERIFY_EXIT=0
VERIFY_OUTPUT="$(bash "$SCRIPT_DIR/verify-n8n.sh" --quiet 2>&1)" || VERIFY_EXIT=$?
# Node lines only (drop the header line)
VERIFY_LINES="$(echo "$VERIFY_OUTPUT" | grep -E '^(✅|❌|❓)' || echo '❓ verify-n8n.sh produced no report')"

{
  echo ""
  echo "── n8n sync check (verify-n8n.sh, exit $VERIFY_EXIT) ──"
  echo "$VERIFY_OUTPUT"
} >> "$RESULT_FILE"

if [ "$VERIFY_EXIT" -eq 0 ]; then
  N8N_MSG="🔗 n8n == repo: all nodes synced"
else
  N8N_MSG="🔗 <b>n8n ≠ repo</b> (Rule 10 — Olaf sync needed):
${VERIFY_LINES}"
fi

# ── Card hygiene check (step [6] discipline) ────────────────────
CARDS_EXIT=0
CARDS_OUTPUT="$(bash "$SCRIPT_DIR/lint-bug-cards.sh" 2>&1)" || CARDS_EXIT=$?
{
  echo ""
  echo "── card hygiene (lint-bug-cards.sh, exit $CARDS_EXIT) ──"
  echo "$CARDS_OUTPUT"
} >> "$RESULT_FILE"
if [ "$CARDS_EXIT" -ne 0 ]; then
  N8N_MSG="${N8N_MSG}

${CARDS_OUTPUT}"
fi

# ── Send Telegram notification ──────────────────────────────────
send_telegram() {
  local message="$1"
  # Alex DM + R4G_Dev_Claude group — both via ClaudeClaw bot
  for cid in 6655962301 -1003599340365; do
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${cid}" \
      -d "text=${message}" \
      -d "parse_mode=HTML" \
      > /dev/null 2>&1
  done
}

if [ "$TEST_EXIT" -eq 0 ]; then
  MSG="✅ <b>R4G nightly tests PASSED</b>
${TESTS_PASSED} tests passed
${SUITES_LINE}
${TIME_LINE}

${N8N_MSG}
📅 ${DATE_STAMP}"
  echo "[OK] All tests passed: $TESTS_PASSED/$TESTS_TOTAL"
else
  # Extract failed test names for the notification
  FAILED_NAMES="$(echo "$TEST_OUTPUT" | grep -E '^\s+●' | head -5 || echo 'See log for details')"
  MSG="❌ <b>R4G nightly tests FAILED</b>
${TESTS_FAILED} failed, ${TESTS_PASSED} passed (${TESTS_TOTAL} total)
${SUITES_LINE}

<b>Failed:</b>
<code>${FAILED_NAMES}</code>

${N8N_MSG}
📅 ${DATE_STAMP}
📄 Log: projects/test-results/r4g-jest-${DATE_STAMP}.txt"
  echo "[FAIL] $TESTS_FAILED failed, $TESTS_PASSED passed"
fi

send_telegram "$MSG"
echo "Telegram notification sent."
echo "Results saved to: $RESULT_FILE"
