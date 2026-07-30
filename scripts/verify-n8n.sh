#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# verify-n8n.sh — R4G: diff live n8n Code nodes against repo files
#
# WORKFLOW.md V2 Rule 10: n8n == repo, both directions are violations.
# Born from the 2026-07-28 incident: the negotiated-price fix sat in git
# since 07-23 while the live ML Accept node ran month-old code.
#
# Read-only: GET only, never writes to n8n. Alerts Telegram on divergence.
#
# Usage: bash scripts/verify-n8n.sh          # report + alert if diverged
#        bash scripts/verify-n8n.sh --quiet  # no Telegram, exit code only
# Exit:  0 = all synced, 1 = divergence found, 2 = API/config error
#
# Known divergences are expected while these cards are open:
#   TASK-20260728-001 (ml_accept), TASK-20260728-002 (ml_state),
#   TASK-20260728-003 (ml_start), netting Compute Plans (card TBD).
# The daily alert doubles as a reminder until they close.
# ─────────────────────────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
R4G_DIR="$PROJECT_ROOT/projects/r4g"

# ── Env: Telegram token from banda .env, n8n key from credentials.env ──
if [ -f "$PROJECT_ROOT/.env" ]; then
  set -a; . "$PROJECT_ROOT/.env"; set +a
fi
N8N_KEY="$(grep '^R4G_N8N_API_KEY=' "$PROJECT_ROOT/secrets/credentials.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]"'"'"'')"
N8N_URL="http://10.128.0.5:5678"
QUIET="${1:-}"

if [ -z "$N8N_KEY" ]; then
  echo "ERROR: R4G_N8N_API_KEY not found in secrets/credentials.env" >&2
  exit 2
fi

# ── Map: workflow_id | node name | repo file ──
# R4G_ML_State_v1_FIXED = keQOweGX4eAkLyUc (active ML workflow)
# R4G_Set1_Solutions_Frontend_v1 = R5LHPUynalETS74X (netting engine)
MAP=(
  "keQOweGX4eAkLyUc|Code: ML Accept FIXED|$R4G_DIR/ml_accept_fix.js"
  "keQOweGX4eAkLyUc|Code: ML Price Proposal|$R4G_DIR/ml_price_proposal.js"
  "keQOweGX4eAkLyUc|Code: Get ML State FIXED|$R4G_DIR/ml_state_fix.js"
  "keQOweGX4eAkLyUc|Code: ML Start|$R4G_DIR/ml_start_fix.js"
  "keQOweGX4eAkLyUc|Code: ML Stop|$R4G_DIR/ml_stop_fix.js"
  "R5LHPUynalETS74X|Compute Plans|$R4G_DIR/netting_compute_plans_v2.js"
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT_EXPECTED="$PROJECT_ROOT/store/verify-n8n-expected.txt"

fetch_workflow() { # $1=id → $TMP/wf_$1.json (cached)
  local id="$1"
  if [ ! -f "$TMP/wf_$id.json" ]; then
    if ! curl -sf -m 20 -H "X-N8N-API-KEY: $N8N_KEY" "$N8N_URL/api/v1/workflows/$id" -o "$TMP/wf_$id.json"; then
      return 1
    fi
  fi
}

REPORT=""
DIVERGED=0
ERRORS=0

for entry in "${MAP[@]}"; do
  IFS='|' read -r wf_id node_name repo_file <<< "$entry"
  short="$(basename "$repo_file")"

  if [ ! -f "$repo_file" ]; then
    REPORT+="❓ $short: repo file missing"$'\n'; ERRORS=1; continue
  fi
  if ! fetch_workflow "$wf_id"; then
    REPORT+="❓ $short: n8n API fetch failed (workflow $wf_id)"$'\n'; ERRORS=1; continue
  fi

  python3 - "$TMP/wf_$wf_id.json" "$node_name" > "$TMP/node.js" <<'PYEOF'
import json, sys
w = json.load(open(sys.argv[1]))
for n in w['nodes']:
    if n['name'] == sys.argv[2] and n['type'].endswith('.code'):
        sys.stdout.write(n['parameters'].get('jsCode', ''))
        sys.exit(0)
sys.exit(3)
PYEOF
  if [ $? -ne 0 ]; then
    REPORT+="❓ $short: node '$node_name' not found in workflow $wf_id"$'\n'; ERRORS=1; continue
  fi

  # Normalize trailing whitespace on both sides before diffing
  DIFF_LINES=$(diff <(sed 's/[[:space:]]*$//' "$repo_file") <(sed 's/[[:space:]]*$//' "$TMP/node.js") | wc -l)
  if [ "$DIFF_LINES" -eq 0 ]; then
    REPORT+="✅ $short == '$node_name'"$'\n'
  else
    # Expected-divergence allowlist: store/verify-n8n-expected.txt,
    # format: "<repo basename>  <reason/card>". Managed by Alex/host only.
    EXPECTED_REASON="$(grep -m1 "^$short" "$ROOT_EXPECTED" 2>/dev/null | cut -d' ' -f2- || true)"
    if [ -n "$EXPECTED_REASON" ]; then
      REPORT+="🟡 $short vs '$node_name': $DIFF_LINES diff lines — EXPECTED ($EXPECTED_REASON)"$'\n'
    else
      REPORT+="❌ $short vs '$node_name': $DIFF_LINES diff lines"$'\n'
      DIVERGED=1
    fi
  fi
done

echo "── R4G n8n sync check ($(date -u '+%Y-%m-%d %H:%M UTC')) ──"
printf '%s' "$REPORT"

EXIT=0
[ "$DIVERGED" -eq 1 ] && EXIT=1
[ "$ERRORS" -eq 1 ] && EXIT=2

if [ "$EXIT" -ne 0 ] && [ "$QUIET" != "--quiet" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  HEADER="⚠️ <b>R4G n8n ≠ repo</b> (Rule 10 check)"
  [ "$ERRORS" -eq 1 ] && HEADER="🔴 <b>R4G n8n check errors</b>"
  MSG="$HEADER
$REPORT
Это ИНФОРМАЦИЯ, не команда: расхождение НЕ означает «синкай». Любой синк —
только по открытой карточке и по команде Alex (Rule 6/10)."
  # Alex DM ONLY. (До 30.07 тут был -1003599340365 из легаси-комментария
  # «R4G_Dev_Claude» — на деле это Auto_Dev_Claude, ДРУГОЙ проект.)
  for cid in 6655962301; do
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${cid}" \
      --data-urlencode "text=${MSG}" \
      -d "parse_mode=HTML" > /dev/null 2>&1
  done
fi

exit $EXIT
