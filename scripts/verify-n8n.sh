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
# Known divergences (expected, tracked in store/verify-n8n-expected.txt) —
# empty as of 2026-09-26 (Olaf, FEAT-20260926-001 sync): the
# netting_compute_plans_v2.js/'Compute Plans' entry dated back to the
# TASK-20260730-001 rollback and was confirmed stale — live had already
# been re-synced to intraBrokerNetting='ml_only' since, the entry just
# never got cleared. Re-add an entry here only for an ACTUAL open,
# deliberate divergence, and remove it the moment that divergence closes —
# a stale entry silences the real drift this script exists to catch.
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
# R4G_ML_State_v1_FIXED    = keQOweGX4eAkLyUc (active ML workflow)
# R4G_Set1_Solutions_Frontend_v1 = R5LHPUynalETS74X (netting engine)
# R4G_BrokerSync_v1        = JRld7fH2T4iMHHKB (client storage: positions, rounds, keys)
# R4G_ShareConfig_v1       = wcvKhSOUyaKzPsAM (client share link)
# R4G_Broker_Config_Sync   = 8ESm4382Ixh2J2cN (account config)
# R4G_MagicLinkAuth_v1     = qxfcoufVHADECeyH (FEAT-20260811-008: login, public webhook r4g/auth)
MAP=(
  "qxfcoufVHADECeyH|Magic Link Auth|$R4G_DIR/magic_link_auth.js"
  "keQOweGX4eAkLyUc|Code: ML Accept FIXED|$R4G_DIR/ml_accept_fix.js"
  "keQOweGX4eAkLyUc|Code: ML Price Proposal|$R4G_DIR/ml_price_proposal.js"
  "keQOweGX4eAkLyUc|Code: Get ML State FIXED|$R4G_DIR/ml_state_fix.js"
  "keQOweGX4eAkLyUc|Code: ML Start|$R4G_DIR/ml_start_fix.js"
  "keQOweGX4eAkLyUc|Code: ML Stop|$R4G_DIR/ml_stop_fix.js"
  "R5LHPUynalETS74X|Compute Plans|$R4G_DIR/netting_compute_plans_v2.js"
  "R5LHPUynalETS74X|Netting Engine Router|$R4G_DIR/netting_engine_router.js"
  "R5LHPUynalETS74X|Parse Webhook Input|$R4G_DIR/netting_parse_webhook_input.js"
  "R5LHPUynalETS74X|Return Summary|$R4G_DIR/netting_return_summary.js"
  "msf8JIo4EPHgs8D1|Identity Store|$R4G_DIR/identity_store.js"

  # ── TASK-20260805-002: 12 repo files found matching live nodes but
  # missing from this MAP (Gale full scan, FEAT-20260805-003 step 0) ──
  "pXoEwtpYF3q5MklB|Compute Internal Netting|$R4G_DIR/internal_netting_v1.js"
  "JuqXmAGnOwEu2EAO|Read iNet History|$R4G_DIR/inet_history_v1.js"
  "pXoEwtpYF3q5MklB|Parse Webhook Input|$R4G_DIR/inet_parse_webhook_input.js"
  "pXoEwtpYF3q5MklB|Inject iNet Credits|$R4G_DIR/inet_inject_credits.js"
  "pXoEwtpYF3q5MklB|Parse Stats Query|$R4G_DIR/parse_stats_query.js"
  "NAPvI3oGvRxRabkt|Read iNet Credits|$R4G_DIR/inet_credits_v1.js"
  "5AYqEk27XKzbmhg8|Broker Auth|$R4G_DIR/broker_auth.js"
  "5AYqEk27XKzbmhg8|Set Broker Password|$R4G_DIR/broker_password_set.js"
  "5AYqEk27XKzbmhg8|Get Broker Passwords|$R4G_DIR/broker_passwords_get.js"
  "Kt71Tsx9cPLTns57|Compute Admin Financials|$R4G_DIR/admin_financials_v1.js"

  # ── Client storage (FEAT-20260805-003 step 0) ──
  # Every Code node of the three storage workflows is mirrored, so a change to
  # how client history is kept can no longer happen outside git.
  "JRld7fH2T4iMHHKB|Store Broker Rows|$R4G_DIR/broker_store_rows.js"
  "JRld7fH2T4iMHHKB|Get All Broker Rows|$R4G_DIR/broker_get_all_rows.js"
  "JRld7fH2T4iMHHKB|Save Netting Results|$R4G_DIR/broker_save_netting_results.js"
  "JRld7fH2T4iMHHKB|Get Netting Results|$R4G_DIR/broker_get_netting_results.js"
  "JRld7fH2T4iMHHKB|Get Netting Log|$R4G_DIR/broker_get_netting_log.js"
  "JRld7fH2T4iMHHKB|Get Trader Log|$R4G_DIR/broker_log_trader.js"
  "JRld7fH2T4iMHHKB|Clear Broker Data|$R4G_DIR/broker_clear_data.js"
  "JRld7fH2T4iMHHKB|Purge Stale Data|$R4G_DIR/broker_purge_stale.js"
  "JRld7fH2T4iMHHKB|Get API Keys|$R4G_DIR/broker_api_keys_get.js"
  "JRld7fH2T4iMHHKB|Generate API Key|$R4G_DIR/broker_api_key_generate.js"
  "JRld7fH2T4iMHHKB|Generate Admin Key|$R4G_DIR/broker_admin_key_generate.js"
  "JRld7fH2T4iMHHKB|Register Callback|$R4G_DIR/broker_callback_register.js"
  "JRld7fH2T4iMHHKB|Get Callbacks|$R4G_DIR/broker_callbacks_get.js"
  "wcvKhSOUyaKzPsAM|Store Config|$R4G_DIR/share_config_store.js"
  "wcvKhSOUyaKzPsAM|Get Config|$R4G_DIR/share_config_get.js"
  "8ESm4382Ixh2J2cN|Store Broker Config|$R4G_DIR/broker_config_store.js"
  "8ESm4382Ixh2J2cN|Return Broker Config|$R4G_DIR/broker_config_return.js"

  # ── TASK-20260805-002: independent full scan, 18 more live nodes with
  # zero repo file (not "not in map" — file didn't exist). Two are real
  # prod endpoints called by frontend/src/config.js (BROKER_CREDIT_*,
  # HUB_PRICES_*) that had NO repo representation at all before this. ──
  "T4JFR1lF7iis0zTt|Compute Plans|$R4G_DIR/set1_solutions_compute_plans.js"
  "T4JFR1lF7iis0zTt|Results Items|$R4G_DIR/set1_solutions_results_items.js"
  "T4JFR1lF7iis0zTt|Details Items|$R4G_DIR/set1_solutions_details_items.js"
  "T4JFR1lF7iis0zTt|Return Summary|$R4G_DIR/set1_solutions_return_summary.js"
  "a0Mmvs3Iz7quHhia|Validate+Build Cycles|$R4G_DIR/set1_loops_validate_build_cycles.js"
  "a0Mmvs3Iz7quHhia|Results Items|$R4G_DIR/set1_loops_results_items.js"
  "a0Mmvs3Iz7quHhia|Loop_Details Items|$R4G_DIR/set1_loops_details_items.js"
  "a0Mmvs3Iz7quHhia|Return Summary|$R4G_DIR/set1_loops_return_summary.js"
  "AibeoQC5WwY5mmN7|Store Broker Credits|$R4G_DIR/broker_credit_store.js"
  "AibeoQC5WwY5mmN7|Get All Credits|$R4G_DIR/broker_credits_get_all.js"
  "AibeoQC5WwY5mmN7|Admin Save Credits|$R4G_DIR/broker_credit_admin_save.js"
  "jB6MiQjZHihD60pf|Parse CSV and Extract Prices|$R4G_DIR/hub_prices_parse_csv.js"
  "jB6MiQjZHihD60pf|Return Stored Prices|$R4G_DIR/hub_prices_get.js"
  "jB6MiQjZHihD60pf|Parse CSV and Extract Prices (Manual)|$R4G_DIR/hub_prices_parse_csv_manual.js"
  "pXoEwtpYF3q5MklB|Parse History Query|$R4G_DIR/inet_parse_history_query.js"
  # BUG-20260905-016 renamed this node: it no longer fetches anything, it states
  # the request. Old entry was "Fetch iNet Data|admin_financials_fetch_inet_data.js".
  "Kt71Tsx9cPLTns57|Prepare iNet Request|$R4G_DIR/admin_financials_prepare_inet_request.js"
  "NAPvI3oGvRxRabkt|Parse POST iNet Credits|$R4G_DIR/inet_credits_parse_post.js"
  "NAPvI3oGvRxRabkt|Parse GET iNet Credits|$R4G_DIR/inet_credits_parse_get.js"

  # ── FEAT-20260805-004: account_purge.js, ONE file deployed unchanged into
  # all six workflows that hold client data (revoke access / delete account) ──
  "JRld7fH2T4iMHHKB|Account Purge|$R4G_DIR/account_purge.js"
  "5AYqEk27XKzbmhg8|Account Purge|$R4G_DIR/account_purge.js"
  "AibeoQC5WwY5mmN7|Account Purge|$R4G_DIR/account_purge.js"
  "pXoEwtpYF3q5MklB|Account Purge|$R4G_DIR/account_purge.js"
  "8ESm4382Ixh2J2cN|Account Purge|$R4G_DIR/account_purge.js"
  "wcvKhSOUyaKzPsAM|Account Purge|$R4G_DIR/account_purge.js"

  # ── FEAT-20260811-009 / TASK-20260812-003: auth_gate.js, ONE file deployed
  # unchanged as the first node of a webhook branch wherever a data node needs
  # __identity. Found live by content match (header comment), was missing
  # from this MAP entirely before TASK-20260812-003's sync. ──
  "JRld7fH2T4iMHHKB|Auth Gate: Store Broker Rows|$R4G_DIR/auth_gate.js"
  "JRld7fH2T4iMHHKB|Auth Gate: Get All Broker Rows|$R4G_DIR/auth_gate.js"
  "JRld7fH2T4iMHHKB|Auth Gate: Get Netting Results|$R4G_DIR/auth_gate.js"
  "JRld7fH2T4iMHHKB|Auth Gate: Get Netting Log|$R4G_DIR/auth_gate.js"
  "JRld7fH2T4iMHHKB|Auth Gate: Register Callback|$R4G_DIR/auth_gate.js"
  "AibeoQC5WwY5mmN7|Auth Gate: Store Broker Credits|$R4G_DIR/auth_gate.js"

  # ── FEAT-20260811-013 precondition 4 (Olaf, 2026-08-13): auth_gate.js
  # added in front of the two receiving webhooks the internal service calls
  # actually target — r4g/admin-financials and r4g/inet-credits had NO gate
  # at all before this. Real workflow IDs, NOT the same-named "[dev]" copies
  # (Kt71Tsx9cPLTns57 / NAPvI3oGvRxRabkt vs K96ncs9UbN3q1drd / xY5R8eL9DrWEqqjg
  # — confirmed by actual webhook path, not by name). ──
  "Kt71Tsx9cPLTns57|Auth Gate: Fetch iNet Data|$R4G_DIR/auth_gate.js"
  "NAPvI3oGvRxRabkt|Auth Gate: Parse POST iNet Credits|$R4G_DIR/auth_gate.js"
  "NAPvI3oGvRxRabkt|Auth Gate: Parse GET iNet Credits|$R4G_DIR/auth_gate.js"

  # ── FEAT-20260811-013 precondition 4, v2 (Olaf, 2026-08-13): service-token.json
  # file pattern replaced process.env (Code nodes can't see it in this n8n —
  # separate process, N8N_BLOCK_ENV_ACCESS_IN_NODE defaults true). New Code node
  # service_token_attach.js sits before each of the 3 internal HTTP callers and
  # leaves a minute-scoped proof on the item for the x-service-proof header. ──
  "pXoEwtpYF3q5MklB|Attach Service Token: Fetch iNet Credits|$R4G_DIR/service_token_attach.js"
  "pXoEwtpYF3q5MklB|Attach Service Token: Record iNet Round to Financials|$R4G_DIR/service_token_attach.js"
  "R5LHPUynalETS74X|Attach Service Token: Record Ext Round to Financials|$R4G_DIR/service_token_attach.js"

  # ── TASK-20260813-006 (Olaf, 2026-08-13): R4G_InternalNetting_v1 was the only
  # active workflow with NO Auth Gate at all — launchedBy (FEAT-20260811-015)
  # was always null and FEAT-20260811-010 role filtering never activated because
  # nothing upstream resolved a session into __identity for this workflow. Pure
  # topology: gate inserted between each of the 3 webhooks and its own parser. ──
  "pXoEwtpYF3q5MklB|Auth Gate: Parse Webhook Input|$R4G_DIR/auth_gate.js"
  "pXoEwtpYF3q5MklB|Auth Gate: Parse History Query|$R4G_DIR/auth_gate.js"
  "pXoEwtpYF3q5MklB|Auth Gate: Parse Stats Query|$R4G_DIR/auth_gate.js"

  # ── TASK-20260905-006 (Olaf, 2026-09-05): self-call httpRequest→localhost
  # nodes replaced by native Execute Workflow. The removed httpRequest nodes
  # ("Fetch iNet Credits", "Record iNet Round to Financials", "Record Ext
  # Round to Financials") never had jsCode and were never in this MAP; the
  # new Execute/Trigger nodes are executeWorkflow(Trigger) type, not .code,
  # so they're not diffable here either — only the new envelope Code nodes
  # need an entry. ──
  "pXoEwtpYF3q5MklB|Envelope: iNet Credits|$R4G_DIR/service_call_inet_credits.js"
  "pXoEwtpYF3q5MklB|Envelope: Record iNet Round|$R4G_DIR/service_call_record_inet_round.js"
  "R5LHPUynalETS74X|Envelope: Record Ext Round|$R4G_DIR/service_call_record_ext_round.js"

  # ── BUG-20260905-016: the Financials tab's iNet figures. The caller's new glue
  # nodes, and — in the callee — a sub-workflow chain of its OWN.
  #
  # The chain duplicates three nodes of the webhook path (gate, parse, compute)
  # because an Execute Workflow node returns `runData[lastNodeExecuted].data.main`:
  # entering the shared graph, which forks into two possible last nodes, put the
  # answer on an output slot the caller was not wired to and returned an empty
  # body (rolled back 2026-09-05). A private single-leaf chain settles the slot
  # structurally.
  #
  # Duplicated code is exactly what this script exists to police, so BOTH copies
  # are listed against the SAME file. The sync script writes them from that file
  # every run; these two lines are what notices if someone edits one of them in
  # the n8n editor. ──
  "Kt71Tsx9cPLTns57|Attach Service Token: iNet Stats|$R4G_DIR/service_token_attach.js"
  "Kt71Tsx9cPLTns57|Envelope: iNet Stats|$R4G_DIR/service_call_inet_stats.js"
  "Kt71Tsx9cPLTns57|Inject iNet Data|$R4G_DIR/admin_financials_inject_inet_data.js"
  "pXoEwtpYF3q5MklB|Auth Gate: Sub-Call iNet Stats|$R4G_DIR/auth_gate.js"
  "pXoEwtpYF3q5MklB|Parse Stats Query (Sub-Call)|$R4G_DIR/parse_stats_query.js"
  "pXoEwtpYF3q5MklB|Compute iNet Stats (Sub-Call)|$R4G_DIR/internal_netting_v1.js"
  "pXoEwtpYF3q5MklB|Return: iNet Stats|$R4G_DIR/inet_stats_subcall_return.js"

  # ── BUG-20260922-009 (Olaf, 2026-09-23): bridge node installed by
  # tools/bug20260922009_file_inet_ml_deals_bridge.py, fans out from Compute
  # Internal Netting. Was missing from this MAP entirely since the node was
  # created (part 2, commit 78871c3) — added now during the part-3 resync so
  # this drift class doesn't repeat (same gap pattern as 'Store iNet Credits'
  # found missing during BUG-20260921-003). ──
  "pXoEwtpYF3q5MklB|Envelope: File iNet ML Deals|$R4G_DIR/service_call_file_inet_ml_deals.js"

  # ── FEAT-20260922-002 (Olaf, 2026-09-23): creditsV2 shadow-mode backend
  # foundation. credit_mode_switch.js is ONE file deployed into every workflow
  # holding a v2 store — same account_purge.js pattern, same reason (n8n gives
  # a node no way to reach another workflow's staticData). n8n enforces webhook
  # paths as GLOBALLY unique, so the two copies can NOT share one path: the
  # R4G_Credit_Save copy keeps the canonical 'r4g/credit-mode-switch' from the
  # file's own header comment, the R4G_INetCredits_v1 copy is on
  # 'r4g/credit-mode-switch-inet-credits' (confirmed live via webhook_entity —
  # registering the same path twice returns HTTP 409 and the second copy's
  # route silently never registers, it does not steal the first copy's route).
  # trader_credits_v2.js is single-instance, R4G_Credit_Save only. ──
  "AibeoQC5WwY5mmN7|Credit Mode Switch|$R4G_DIR/credit_mode_switch.js"
  "NAPvI3oGvRxRabkt|Credit Mode Switch|$R4G_DIR/credit_mode_switch.js"
  "AibeoQC5WwY5mmN7|Trader Credits V2|$R4G_DIR/trader_credits_v2.js"

  # ── FEAT-20260922-004 (Gale, 2026-09-25): the gate in FRONT of those two.
  # credit_mode_switch.js gained a second door — a company-wide session may
  # switch its own broker — and it reads that session from `__identity`, which
  # only auth_gate.js ever writes. Both copies shipped WITHOUT a gate ahead of
  # them, so __identity was null on every request and a genuine broker session
  # got the endpoint's last-resort refusal (Kim, 2026-09-24, reproduced live 3x
  # while the cookie was demonstrably arriving). Listed here because the wiring
  # is only half the fix: a gate carrying a stale copy is the same outage with a
  # longer diagnosis. Graph shape itself is pinned by
  # frontend/__tests__/unit/workflows/creditModeSwitchAuthGateWiringFEAT20260922004.test.js. ──
  "AibeoQC5WwY5mmN7|Auth Gate: Credit Mode Switch|$R4G_DIR/auth_gate.js"
  "NAPvI3oGvRxRabkt|Auth Gate: Credit Mode Switch|$R4G_DIR/auth_gate.js"
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
