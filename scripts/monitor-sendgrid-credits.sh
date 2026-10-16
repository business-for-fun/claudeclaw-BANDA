#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# monitor-sendgrid-credits.sh — TASK-20261016-008
#
# External (outside n8n) watchdog for the SendGrid account `R4G_MagicLinkAuth_v1`
# sends through. Polls `/v3/user/credits` (and the day's `/v3/stats`, for
# context in the alert) and pages Telegram when the account looks dead.
#
# ── Why this exists (BUG-20261016-015) ───────────────────────────────────────
# SendGrid exhausted its credits on 2026-10-01 and nobody noticed until
# 2026-10-16, because a 401 at the SendGrid API border never shows up in
# SendGrid's own `/v3/stats` ("zero requests" proves nothing), and
# `R4G_MagicLinkAuth_v1`'s n8n execution save is deliberately off (the
# payload carries a live magic link — see magic_link_auth.js). This script is
# the thing that would have caught it on 2026-10-01: it asks SendGrid itself,
# not n8n, and it does not care whether anyone tried to log in.
#
# ── What actually flags trouble ──────────────────────────────────────────────
#   1. `remain` near zero — the account cannot send right now.
#   2. `next_reset` in the past — the signature BUG-20261016-015 found: a
#      healthy daily/monthly plan's next reset date is always in the future.
#      Two weeks of `next_reset: 2026-10-02` while the date was 2026-10-16 is
#      exactly what "frozen/expired plan" looks like, and this check is a
#      direct read of that same field, not an inference from send volume.
# Either one alone is enough to page — they are two independent symptoms of
# the same underlying failure (frozen free plan), and the incident this exists
# to prevent had BOTH at once.
#
# ── Alerting ─────────────────────────────────────────────────────────────────
# Same channel and chat ids as the nightly Jest/n8n-backup jobs
# (scripts/run-r4g-tests.sh, scripts/backup-n8n-workflows.sh): Alex DM
# (6655962301) + R4G_Debug group (-1003759375768), NOT Auto_Dev_Claude.
# Throttled to one page per ALERT_THROTTLE_S while the condition persists
# (a frozen plan does not need an hourly repeat of the same page for two
# weeks), and a single "recovered" message when it clears.
#
# Usage:   bash scripts/monitor-sendgrid-credits.sh [--dry-run]
#          --dry-run: evaluate and log exactly as a real run would, but never
#          call Telegram and never update the throttle state file. For
#          checking the script's own logic against the live account without
#          disturbing the real alert/recovery state machine.
# Cron:    hourly — catches a repeat within the hour (acceptance criterion),
#          not the two weeks BUG-20261016-015 actually took.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$PROJECT_ROOT/secrets"

STATE_DIR="$PROJECT_ROOT/projects/r4g/logs"
STATE_FILE="$STATE_DIR/sendgrid-credits-monitor-state.json"
mkdir -p "$STATE_DIR"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# ── Secrets ──────────────────────────────────────────────────────────────────
# Telegram bot token lives in .env (same place run-r4g-tests.sh and
# backup-n8n-workflows.sh read it from). SendGrid's key is a credential, so it
# lives in secrets/credentials.env (CLAUDE.md Credentials Storage Rule), NOT
# in .env.
BOT_TOKEN=""
if [ -f "$PROJECT_ROOT/.env" ]; then
  BOT_TOKEN=$(grep "^TELEGRAM_BOT_TOKEN=" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2-)
fi

SENDGRID_API_KEY=""
if [ -f "$SECRETS_DIR/credentials.env" ]; then
  SENDGRID_API_KEY=$(grep -m1 "^SENDGRID_API_KEY=" "$SECRETS_DIR/credentials.env" 2>/dev/null | cut -d= -f2-)
fi

if [ -z "$SENDGRID_API_KEY" ]; then
  log "ERROR: no SENDGRID_API_KEY in $SECRETS_DIR/credentials.env — cannot poll, cannot alert about this honestly without the key"
  exit 1
fi

ALERT_THROTTLE_S=$((6 * 3600))   # one page per 6h while the condition persists

send_telegram() {
  local message="$1"
  if [ -z "$BOT_TOKEN" ]; then
    log "ERROR: no TELEGRAM_BOT_TOKEN in $PROJECT_ROOT/.env, could not page — see message below"
    log "$message"
    return
  fi
  # Alex DM + R4G_Debug group (NOT Auto_Dev_Claude — inцидент 30.07, see
  # run-r4g-tests.sh / backup-n8n-workflows.sh for the same rule).
  for cid in 6655962301 -1003759375768; do
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${cid}" \
      -d "text=${message}" \
      -d "parse_mode=HTML" \
      > /dev/null 2>&1
  done
}

# ── Poll SendGrid ────────────────────────────────────────────────────────────
TODAY="$(date -u +%Y-%m-%d)"

CREDITS_JSON="$(curl -s --connect-timeout 10 --max-time 20 \
  -H "Authorization: Bearer ${SENDGRID_API_KEY}" \
  "https://api.sendgrid.com/v3/user/credits" 2>/dev/null)"

if [ -z "$CREDITS_JSON" ]; then
  log "ERROR: no response from SendGrid /v3/user/credits (network?)"
  exit 1
fi

STATS_JSON="$(curl -s --connect-timeout 10 --max-time 20 \
  -H "Authorization: Bearer ${SENDGRID_API_KEY}" \
  "https://api.sendgrid.com/v3/stats?start_date=${TODAY}&aggregated_by=day" 2>/dev/null)"

# ── Evaluate + alert (all logic in one python3 pass: JSON, date math, state) ─
# Captured, not streamed straight to the terminal: the only two line shapes
# that matter are `ALERT_RAW::<message>` (zero, one or two of them — a page
# and/or a recovery notice) and the final `OK ...` summary, and bash below
# acts on exactly those, nothing else.
PY_OUTPUT="$(python3 - "$CREDITS_JSON" "$STATS_JSON" "$STATE_FILE" "$ALERT_THROTTLE_S" "$TODAY" "$DRY_RUN" <<'PYEOF'
import json
import sys
import time

credits_raw, stats_raw, state_file, throttle_s, today, dry_run = sys.argv[1:7]
throttle_s = int(throttle_s)
dry_run = dry_run == '1'
now = int(time.time())

def load_state():
    try:
        with open(state_file) as f:
            return json.load(f)
    except Exception:
        return {}

def save_state(state):
    if dry_run:
        return
    tmp = state_file + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(state, f, indent=2)
    import os
    os.replace(tmp, state_file)

# Lines bash acts on are prefixed and JSON-encoded on ONE line each — an
# alert message contains literal newlines, and a plain `print(f"...\n...")`
# would silently split across several lines of stdout, which the bash loop
# below reads one line at a time. json.dumps collapses it back to one line;
# bash decodes it back to real newlines right before handing it to curl.
def emit_alert(msg):
    print("ALERT_JSON::" + json.dumps(msg))

try:
    credits = json.loads(credits_raw)
except Exception as e:
    emit_alert(f"\U0001F534 [SendGrid monitor] /v3/user/credits returned unparseable JSON — treating as an outage, not a quiet night: {credits_raw[:200]!r}")
    print("OK parse-error")
    sys.exit(0)

if not isinstance(credits, dict) or 'remain' not in credits:
    # An auth failure (expired/rotated key) is valid JSON but has no 'remain' —
    # same trap as backup-n8n-workflows.sh's TASK-20260908-001: failing loudly
    # here instead of silently treating it as "credits fine" is the point.
    emit_alert(f"\U0001F534 [SendGrid monitor] /v3/user/credits did not return a credits object (expired/rotated key, or API shape changed): {json.dumps(credits)[:300]}")
    print("OK no-credits-field")
    sys.exit(0)

remain = credits.get('remain')
total = credits.get('total')
next_reset = credits.get('next_reset')
last_reset = credits.get('last_reset')
is_hard_limit = credits.get('is_hard_limit')
reset_frequency = credits.get('reset_frequency')

REMAIN_FLOOR = 10
low_absolute = isinstance(remain, (int, float)) and remain <= REMAIN_FLOOR
low_ratio = (isinstance(remain, (int, float)) and isinstance(total, (int, float))
             and total > 0 and remain <= total * 0.05)
credits_low = bool(low_absolute or low_ratio)

# The BUG-20261016-015 fingerprint: a healthy plan's next reset is always in
# the future. String comparison is safe here because both this script and
# SendGrid use ISO 'YYYY-MM-DD'.
reset_frozen = bool(next_reset) and str(next_reset) <= today

alerting = credits_low or reset_frozen

# Stats, for context only — NOT a trigger. BUG-20261016-015 proved a 401 at
# the API border does not appear here, so "today: 0 requests" is not evidence
# of anything by itself; it rides along in the message so a human does not
# have to re-derive it.
stats_note = ""
try:
    stats = json.loads(stats_raw)
    if isinstance(stats, list) and stats:
        day = stats[0]
        metrics = (day.get('stats') or [{}])[0].get('metrics', {})
        requests = metrics.get('requests', '?')
        stats_note = f"\n/v3/stats today ({today}): {requests} requests (0 here does NOT mean nothing was sent — 401s never appear in this stat)"
except Exception:
    pass

state = load_state()
prev_alerting = state.get('alerting', False)
prev_alert_ts = state.get('last_alert_ts', 0)

reasons = []
if credits_low:
    reasons.append(f"remain={remain}" + (f"/{total}" if isinstance(total, (int, float)) else "") + " (near zero)")
if reset_frozen:
    reasons.append(f"next_reset={next_reset} is in the past as of {today} (reset cycle looks frozen)")

if alerting:
    should_send = (not prev_alerting) or (now - prev_alert_ts >= throttle_s)
    if should_send:
        msg = (
            "\U0001F534 <b>SendGrid account looks dead (R4G_MagicLinkAuth_v1)</b>\n"
            + "; ".join(reasons) + "\n"
            f"last_reset={last_reset} reset_frequency={reset_frequency} is_hard_limit={is_hard_limit}"
            + stats_note +
            "\n\nMagic-link sign-in email will NOT be delivered until this is fixed "
            "(pay/reactivate the SendGrid plan — not a code fix, see BUG-20261016-015)."
        )
        emit_alert(msg)
        state['last_alert_ts'] = now
    state['alerting'] = True
    state['last_check'] = {'remain': remain, 'total': total, 'next_reset': next_reset, 'ts': now}
    save_state(state)
else:
    if prev_alerting:
        msg = (
            "✅ <b>SendGrid account recovered (R4G_MagicLinkAuth_v1)</b>\n"
            f"remain={remain}" + (f"/{total}" if isinstance(total, (int, float)) else "") +
            f" next_reset={next_reset} (now in the future)"
        )
        emit_alert(msg)
    state['alerting'] = False
    state['last_check'] = {'remain': remain, 'total': total, 'next_reset': next_reset, 'ts': now}
    save_state(state)

print(f"OK remain={remain} total={total} next_reset={next_reset} credits_low={credits_low} reset_frozen={reset_frozen} alerting={alerting}")
PYEOF
)"
PY_EXIT=$?

if [ "$PY_EXIT" -ne 0 ]; then
  log "ERROR: evaluation script failed (exit $PY_EXIT)"
  log "$PY_OUTPUT"
  exit 1
fi

# ── Act on the evaluation: zero, one or two ALERT_JSON lines, then one OK line.
while IFS= read -r line; do
  case "$line" in
    ALERT_JSON::*)
      payload="${line#ALERT_JSON::}"
      # Decode the JSON string back to real text (real newlines included)
      # OUTSIDE of bash's own line-based reading — this is exactly why the
      # message travelled as JSON rather than as a raw multi-line value.
      text="$(python3 -c 'import json,sys; sys.stdout.write(json.loads(sys.argv[1]))' "$payload")"
      if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN, not sending. Would page:"
        log "$text"
      else
        log "ALERT: $text"
        send_telegram "$text"
      fi
      ;;
    OK*)
      log "$line"
      ;;
    *)
      log "$line"
      ;;
  esac
done <<< "$PY_OUTPUT"
