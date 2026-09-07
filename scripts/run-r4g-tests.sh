#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# R4G Nightly Test Runner
# Runs Jest test suite + n8n sync check (verify-n8n.sh, Rule 10),
# saves results, notifies via Telegram in ONE morning message.
#
# ── TASK-20260907-001: per-step timeout budgets, no silent section loss ──
#
# This script is fired by BANDA's own scheduler (banda/src/scheduler.ts),
# which hard-kills the WHOLE agent turn running it after
# TASK_TIMEOUT_MS = 10 minutes (a global constant shared by every scheduled
# job in the fleet — not something this script can see or extend). Before
# this card the script ran every step as one opaque blocking call with no
# internal bound: Jest + verify-n8n.sh + lint-bug-cards.sh +
# lint-e2e-guard-imports.sh + smoke-e2e-specs.sh, in that order, and the
# Telegram notification only fires at the very end, after all five. As the
# e2e suite and the Jest suite both grew (69 -> 106 e2e specs and 273 -> 343
# Jest suites between 2026-08-15 and 2026-09-07), the pipeline's real
# duration crossed 10 minutes around 2026-09-03: measured live on 2026-09-07,
# before Olaf's fix below, the five steps summed to ~603s — a hair over the
# 600s outer kill. Every night since, the scheduler killed the run mid
# smoke-e2e-specs.sh (the last, longest step): its section never got
# appended to the result file, AND the final send_telegram call never ran —
# nobody was told anything, for 5 nights, because the failure mode was
# silence rather than a red build.
#
# Two changes fix this:
#  1. smoke-e2e-specs.sh itself now runs its live-start checks in parallel
#     instead of serially (see its own header) — 6m06s -> ~1m12s measured on
#     the same 106-file suite, restoring real headroom instead of just
#     delaying the next overrun.
#  2. Every step below runs under its own `timeout -s KILL <budget>`
#     (run_step, right below) — a circuit breaker, not the primary fix. If
#     any single step ever runs away (a hung test, a network stall despite
#     the egress guard, organic growth nobody watched), THAT step is killed
#     on its own schedule, explicitly marked "⏱ TIMEOUT" in both the result
#     file and the Telegram message, and the script moves on to the
#     remaining steps and — critically — still reaches send_telegram at the
#     end. Sum of budgets is ~520s, comfortably under the 600s external
#     kill even in the worst case where every step maxes out its own budget.
#     A step that times out is a loud, visible FAIL; a step that is merely
#     slow no longer costs every step after it its own report.
#
# Usage: bash scripts/run-r4g-tests.sh
# Cron:  0 2 * * * (daily at 02:00 UTC)
# ─────────────────────────────────────────────────────────────────
# `-e` deliberately dropped (was `-euo pipefail`): the whole point of this
# card is that the script must reach `send_telegram` at the end no matter
# what any individual step does, including a step killed by `timeout -s
# KILL` below (exit 137). `-e` would abort the script the moment any such
# assignment's exit status is non-zero — exactly the silent-loss failure
# mode this card exists to remove. Every step's exit code is still captured
# and checked explicitly (`run_step` / the pre-existing `|| VAR=$?` calls).
set -uo pipefail
PIPELINE_START_S=$(date +%s)

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

# ── Per-step timeout budgets (TASK-20260907-001) ─────────────────
# Sum = 520s, comfortably under the scheduler's 600s (10 min) outer kill —
# see the header comment for why these five numbers and not the whole
# 600s. Each is generous vs. today's measured usage (Jest ~218s,
# verify-n8n.sh ~9s, lint-bug-cards.sh ~9s, lint-e2e-guard-imports.sh ~1s,
# smoke-e2e-specs.sh ~72s after parallelising it) so a normal night never
# gets near its cap — these exist to bound the ABNORMAL night.
JEST_TIMEOUT_S=270
VERIFY_TIMEOUT_S=45
CARDS_TIMEOUT_S=45
GUARD_TIMEOUT_S=30
SMOKE_TIMEOUT_S=180

# Runs "$@" under a KILL timeout, sets STEP_OUTPUT/STEP_EXIT/STEP_TIMED_OUT.
# A killed step (exit 137) gets an explicit "⏱ TIMEOUT" line appended to its
# own output — the report never has to infer a timeout from an empty
# section, because the section is never empty: it always says what happened.
run_step() {
  local budget="$1" label="$2"; shift 2
  local out exit_code
  out="$(timeout -s KILL "$budget" "$@" 2>&1)"
  exit_code=$?
  STEP_TIMED_OUT=0
  if [ "$exit_code" -eq 137 ]; then
    STEP_TIMED_OUT=1
    out="${out}
⏱ TIMEOUT: $label killed after ${budget}s (TASK-20260907-001 budget) — this run's result for this step is INCOMPLETE, not a clean pass or a real failure."
  fi
  STEP_OUTPUT="$out"
  STEP_EXIT="$exit_code"
}

# ── Run tests ───────────────────────────────────────────────────
echo "[$DATE_STAMP] Running R4G Jest tests..."

cd "$FRONTEND_DIR"

run_step "$JEST_TIMEOUT_S" "Jest" npm test -- --ci --forceExit
TEST_OUTPUT="$STEP_OUTPUT"
TEST_EXIT="$STEP_EXIT"
TEST_TIMED_OUT="$STEP_TIMED_OUT"

# Save full output
echo "$TEST_OUTPUT" > "$RESULT_FILE"
echo "" >> "$RESULT_FILE"
echo "Exit code: $TEST_EXIT" >> "$RESULT_FILE"
echo "Timed out: $TEST_TIMED_OUT (budget ${JEST_TIMEOUT_S}s)" >> "$RESULT_FILE"
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
run_step "$VERIFY_TIMEOUT_S" "verify-n8n.sh" bash "$SCRIPT_DIR/verify-n8n.sh" --quiet
VERIFY_OUTPUT="$STEP_OUTPUT"
VERIFY_EXIT="$STEP_EXIT"
VERIFY_TIMED_OUT="$STEP_TIMED_OUT"
# Node lines only (drop the header line)
VERIFY_LINES="$(echo "$VERIFY_OUTPUT" | grep -E '^(✅|❌|❓)' || echo '❓ verify-n8n.sh produced no report')"

{
  echo ""
  echo "── n8n sync check (verify-n8n.sh, exit $VERIFY_EXIT) ──"
  echo "$VERIFY_OUTPUT"
} >> "$RESULT_FILE"

if [ "$VERIFY_TIMED_OUT" -eq 1 ]; then
  N8N_MSG="🔗⏱ <b>n8n sync check TIMED OUT</b> after ${VERIFY_TIMEOUT_S}s — not verified this run."
elif [ "$VERIFY_EXIT" -eq 0 ]; then
  N8N_MSG="🔗 n8n == repo: all nodes synced"
else
  N8N_MSG="🔗 <b>n8n ≠ repo</b> (Rule 10 — Olaf sync needed):
${VERIFY_LINES}"
fi

# ── Card hygiene check (step [6] discipline) ────────────────────
run_step "$CARDS_TIMEOUT_S" "lint-bug-cards.sh" bash "$SCRIPT_DIR/lint-bug-cards.sh"
CARDS_OUTPUT="$STEP_OUTPUT"
CARDS_EXIT="$STEP_EXIT"
CARDS_TIMED_OUT="$STEP_TIMED_OUT"
{
  echo ""
  echo "── card hygiene (lint-bug-cards.sh, exit $CARDS_EXIT) ──"
  echo "$CARDS_OUTPUT"
} >> "$RESULT_FILE"
if [ "$CARDS_TIMED_OUT" -eq 1 ]; then
  N8N_MSG="${N8N_MSG}

⏱ <b>card hygiene check TIMED OUT</b> after ${CARDS_TIMEOUT_S}s — not run this night."
elif [ "$CARDS_EXIT" -ne 0 ]; then
  N8N_MSG="${N8N_MSG}

${CARDS_OUTPUT}"
fi

# ── e2e guard-fixture regression check (TASK-20260805-001) ──────
# Protects FEAT-20260805-001's shared Playwright isolation guard from
# rotting: a new *.spec.js that drives a browser with zero write
# interception (or switches to @playwright/test, bypassing the fixture
# entirely) is exactly the BUG-20260804-018 class of risk recurring.
run_step "$GUARD_TIMEOUT_S" "lint-e2e-guard-imports.sh" bash "$SCRIPT_DIR/lint-e2e-guard-imports.sh"
GUARD_OUTPUT="$STEP_OUTPUT"
GUARD_EXIT="$STEP_EXIT"
GUARD_TIMED_OUT="$STEP_TIMED_OUT"
{
  echo ""
  echo "── e2e guard-fixture check (lint-e2e-guard-imports.sh, exit $GUARD_EXIT) ──"
  echo "$GUARD_OUTPUT"
} >> "$RESULT_FILE"
if [ "$GUARD_TIMED_OUT" -eq 1 ]; then
  N8N_MSG="${N8N_MSG}

⏱ <b>e2e guard-fixture check TIMED OUT</b> after ${GUARD_TIMEOUT_S}s — not run this night."
elif [ "$GUARD_EXIT" -ne 0 ]; then
  N8N_MSG="${N8N_MSG}

🛡️ <b>e2e guard regression (TASK-20260805-001)</b>:
${GUARD_OUTPUT}"
fi

# ── e2e startup smoke check (BUG-20260805-006 Part 3) ────────────
# Cheap "does it even start" pass over every *.spec.js — catches the exact
# silent-breakage class BUG-20260805-006 was (12 files unrunnable for 6
# days, nothing in the nightly run ever executed them). Not a full scenario
# run — see smoke-e2e-specs.sh header for the classification rules.
# TASK-20260907-001: smoke-e2e-specs.sh now parallelises its own live-start
# loop internally; this outer timeout is a second-layer circuit breaker,
# not the primary defence against slowness.
run_step "$SMOKE_TIMEOUT_S" "smoke-e2e-specs.sh" bash "$SCRIPT_DIR/smoke-e2e-specs.sh"
SMOKE_OUTPUT="$STEP_OUTPUT"
SMOKE_EXIT="$STEP_EXIT"
SMOKE_TIMED_OUT="$STEP_TIMED_OUT"
{
  echo ""
  echo "── e2e startup smoke (smoke-e2e-specs.sh, exit $SMOKE_EXIT) ──"
  echo "$SMOKE_OUTPUT"
} >> "$RESULT_FILE"
if [ "$SMOKE_TIMED_OUT" -eq 1 ]; then
  N8N_MSG="${N8N_MSG}

🧪⏱ <b>e2e startup smoke TIMED OUT</b> after ${SMOKE_TIMEOUT_S}s (TASK-20260907-001) — section is INCOMPLETE, not a clean pass. This is exactly the failure mode that went unnoticed for 5 nights (2026-09-03..07) before this card; it is no longer silent."
elif [ "$SMOKE_EXIT" -ne 0 ]; then
  N8N_MSG="${N8N_MSG}

🧪 <b>e2e startup smoke FAILED (BUG-20260805-006)</b>:
${SMOKE_OUTPUT}"
fi

# ── Overall run bookkeeping ───────────────────────────────────────
PIPELINE_END_S=$(date +%s)
PIPELINE_ELAPSED_S=$((PIPELINE_END_S - PIPELINE_START_S))
echo "" >> "$RESULT_FILE"
echo "── pipeline wall time: ${PIPELINE_ELAPSED_S}s (budget sum: $((JEST_TIMEOUT_S + VERIFY_TIMEOUT_S + CARDS_TIMEOUT_S + GUARD_TIMEOUT_S + SMOKE_TIMEOUT_S))s, scheduler kill: 600s) ──" >> "$RESULT_FILE"

ANY_TIMEOUT=0
if [ "$TEST_TIMED_OUT" -eq 1 ] || [ "$VERIFY_TIMED_OUT" -eq 1 ] || [ "$CARDS_TIMED_OUT" -eq 1 ] \
   || [ "$GUARD_TIMED_OUT" -eq 1 ] || [ "$SMOKE_TIMED_OUT" -eq 1 ]; then
  ANY_TIMEOUT=1
fi

# ── Send Telegram notification ──────────────────────────────────
send_telegram() {
  local message="$1"
  # Alex DM + R4G_Debug group (НЕ Auto_Dev_Claude! чужой проект — инцидент 30.07)
  for cid in 6655962301 -1003759375768; do
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${cid}" \
      -d "text=${message}" \
      -d "parse_mode=HTML" \
      > /dev/null 2>&1
  done
}

INCOMPLETE_BANNER=""
if [ "$ANY_TIMEOUT" -eq 1 ]; then
  INCOMPLETE_BANNER="⚠️ <b>INCOMPLETE RUN — at least one step timed out, see below</b>
"
fi

if [ "$TEST_TIMED_OUT" -eq 1 ]; then
  MSG="${INCOMPLETE_BANNER}⏱ <b>R4G nightly tests: Jest TIMED OUT</b> after ${JEST_TIMEOUT_S}s — no pass/fail verdict this run

${N8N_MSG}
⏲️ pipeline wall time: ${PIPELINE_ELAPSED_S}s
📅 ${DATE_STAMP}
📄 Log: projects/test-results/r4g-jest-${DATE_STAMP}.txt"
  echo "[TIMEOUT] Jest killed after ${JEST_TIMEOUT_S}s, no verdict"
elif [ "$TEST_EXIT" -eq 0 ]; then
  MSG="${INCOMPLETE_BANNER}✅ <b>R4G nightly tests PASSED</b>
${TESTS_PASSED} tests passed
${SUITES_LINE}
${TIME_LINE}

${N8N_MSG}
⏲️ pipeline wall time: ${PIPELINE_ELAPSED_S}s
📅 ${DATE_STAMP}"
  echo "[OK] All tests passed: $TESTS_PASSED/$TESTS_TOTAL"
else
  # Extract failed test names for the notification
  FAILED_NAMES="$(echo "$TEST_OUTPUT" | grep -E '^\s+●' | head -5 || echo 'See log for details')"
  MSG="${INCOMPLETE_BANNER}❌ <b>R4G nightly tests FAILED</b>
${TESTS_FAILED} failed, ${TESTS_PASSED} passed (${TESTS_TOTAL} total)
${SUITES_LINE}

<b>Failed:</b>
<code>${FAILED_NAMES}</code>

${N8N_MSG}
⏲️ pipeline wall time: ${PIPELINE_ELAPSED_S}s
📅 ${DATE_STAMP}
📄 Log: projects/test-results/r4g-jest-${DATE_STAMP}.txt"
  echo "[FAIL] $TESTS_FAILED failed, $TESTS_PASSED passed"
fi

send_telegram "$MSG"
echo "Telegram notification sent."
echo "Results saved to: $RESULT_FILE"
