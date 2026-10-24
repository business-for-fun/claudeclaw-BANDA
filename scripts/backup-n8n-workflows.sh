#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# backup-n8n-workflows.sh — Export all n8n workflows as JSON files
#
# Connects to all project n8n servers, exports each workflow as a
# separate JSON file into projects/{project}/workflows/, then commits
# any changes to git.
#
# Routing by workflow name prefix:
#   - Name contains "LIMO"    → projects/limo/workflows/
#   - Name contains "FAM"     → projects/fam/workflows/
#   - Name contains "AGENTPM" → projects/agentpm/workflows/
#   - Name contains "IPA"     → projects/ipa/workflows/
#   - Everything else         → projects/r4g/workflows/
#
# NOTE: the r4g n8n server (10.128.0.5) hosts workflows for multiple
# unrelated things beyond R4G itself (AgentPM/IPA routed out above; also
# assorted YCA_*, Majordom/EXECUTOR_*, and generic scratch/test workflows
# that don't have a clear project home yet — those still fall through to
# r4g/workflows/ as of 2026-07-26 pending a decision on where they belong).
#
# Usage:
#   bash scripts/backup-n8n-workflows.sh          # run manually
#   node dist/schedule-cli.js create \
#     'bash scripts/backup-n8n-workflows.sh' '0 3 * * *'  # daily 03:00 UTC
#
# Requires: curl, python3, sqlite3, git
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="$PROJECT_ROOT/secrets"

# ── n8n server definitions ──
# Format: "label|host|api_key_file"
#
# TASK-20260908-001 (Olaf, 2026-09-08): LIMO's n8n workflows (Poller,
# Booking.com webhooks, Sheets-sync) migrated off 10.128.0.7 to the FAM host
# 10.128.0.3 on 2026-08-19 (see memory chunk BUG-20260819-001 / card
# TASK-20260815-004). On 2026-08-20 the old LIMO VM (10.128.0.7) was torn
# down and repurposed as R4G-PROD/VM3 — that address now hosts an unrelated
# n8n instance (R4G sandbox, sandbox.ready2net.online) whose n8n only binds
# 127.0.0.1:5678 and was never reachable on this port from other hosts in
# the first place. Pointing "limo" at 10.128.0.7 here was stale since the
# migration: every nightly run failed with "Cannot reach" for limo, not
# because anything was down, but because the address was simply wrong.
# Fixed: limo now shares the same host+port as fam (10.128.0.3), matching
# where the LIMO workflows actually live today. Keep the API key file
# separate (limo_n8n_api_key) in case LIMO ever gets its own key again.
SERVERS=(
  "r4g|http://10.128.0.5:5678|$SECRETS_DIR/r4g_n8n_api_key"
  "limo|http://10.128.0.3:5678|$SECRETS_DIR/limo_n8n_api_key"
  "fam|http://10.128.0.3:5678|$SECRETS_DIR/fam_n8n_api_key"
)

# ── Output directories ──
R4G_DIR="$PROJECT_ROOT/projects/r4g/workflows"
LIMO_DIR="$PROJECT_ROOT/projects/limo/workflows"
FAM_DIR="$PROJECT_ROOT/projects/fam/workflows"
AGENTPM_DIR="$PROJECT_ROOT/projects/agentpm/workflows"
IPA_DIR="$PROJECT_ROOT/projects/ipa/workflows"

mkdir -p "$R4G_DIR" "$LIMO_DIR" "$FAM_DIR" "$AGENTPM_DIR" "$IPA_DIR"

TOTAL_EXPORTED=0
TOTAL_CHANGED=0

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Sanitize workflow name for filesystem ──
sanitize_name() {
  # Replace spaces and special chars with underscores, keep alphanumeric + dash + underscore
  echo "$1" | sed 's/[^a-zA-Z0-9._-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//'
}

# ── Route workflow to the correct project directory by name ──
route_workflow() {
  local name="$1"
  local name_upper
  name_upper=$(echo "$name" | tr '[:lower:]' '[:upper:]')

  if echo "$name_upper" | grep -q "LIMO"; then
    echo "$LIMO_DIR"
  elif echo "$name_upper" | grep -q "FAM"; then
    echo "$FAM_DIR"
  elif echo "$name_upper" | grep -q "AGENTPM"; then
    echo "$AGENTPM_DIR"
  elif echo "$name_upper" | grep -q "IPA"; then
    echo "$IPA_DIR"
  else
    echo "$R4G_DIR"
  fi
}

# ── Export workflows from one n8n server ──
export_from_server() {
  local label="$1"
  local host="$2"
  local key_file="$3"

  if [ ! -f "$key_file" ] || [ ! -r "$key_file" ]; then
    log "SKIP $label: API key file not found or not readable ($key_file)"
    return
  fi

  local api_key
  api_key=$(cat "$key_file") || { log "SKIP $label: cannot read API key"; return; }

  log "Fetching workflows from $label ($host)..."

  # TASK-20260905-007 (Olaf, 2026-09-05): n8n's /api/v1/workflows is paginated
  # (default page size 100, more pages signalled via `nextCursor`). This used
  # to be a single unconditional curl call with no `limit`/`cursor` handling
  # at all — any server with >100 live workflows silently lost everything
  # past the first page, forever, with no error (found by Gale on r4g:
  # 121 live workflows, 21 never backed up, including 2 dev workflows from
  # the TASK-006 iNet/Financials chain). Fix: follow `nextCursor` in a loop,
  # merging each page's `data` array before handing off to the existing
  # validate/count/export logic below (which is unchanged and still expects
  # a single {"data": [...]} response — this loop just builds that).
  local response
  local pages_file
  pages_file=$(mktemp)
  local cursor=""
  local page_num=0

  while true; do
    page_num=$((page_num + 1))
    local url="$host/api/v1/workflows?limit=100"
    if [ -n "$cursor" ]; then
      url="${url}&cursor=${cursor}"
    fi

    local page_json
    page_json=$(curl -s --connect-timeout 10 --max-time 30 \
      -H "X-N8N-API-KEY: $api_key" \
      "$url" 2>/dev/null) || {
      log "ERROR: Cannot reach $label at $host (page $page_num)"
      rm -f "$pages_file"
      return
    }

    if ! echo "$page_json" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
      log "ERROR: Invalid JSON response from $label (page $page_num)"
      rm -f "$pages_file"
      return
    fi

    # TASK-20260908-001 (Olaf, 2026-09-08): n8n answers an expired/invalid
    # API key with HTTP 401 + {"message":"Unauthorized"} — still valid JSON,
    # and .get('data',[]) on it silently evaluates to an empty list. Before
    # this check, an auth failure was indistinguishable from "this server
    # genuinely has zero workflows" and was logged as the latter, hiding the
    # real problem (found while investigating this task: fam/limo API keys
    # are stale, confirmed via direct curl — 401 on both). Fail loudly
    # instead of silently reporting "no workflows found".
    if ! echo "$page_json" | python3 -c "import sys,json; sys.exit(0 if 'data' in json.load(sys.stdin) else 1)" 2>/dev/null; then
      log "ERROR: $label API rejected the request (no 'data' field in response, page $page_num): $(echo "$page_json" | head -c 200)"
      rm -f "$pages_file"
      return
    fi

    echo "$page_json" >> "$pages_file"

    local page_count
    page_count=$(echo "$page_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))")
    cursor=$(echo "$page_json" | python3 -c "import sys,json; c=json.load(sys.stdin).get('nextCursor'); print(c if c else '')")
    log "  $label: page $page_num fetched ($page_count workflows)$([ -n "$cursor" ] && echo ", more pages pending" || echo ", last page")"

    if [ -z "$cursor" ]; then
      break
    fi
  done

  # Merge all pages' `data` arrays into one combined response, same shape
  # the rest of this function already expects.
  response=$(python3 -c "
import json
items = []
with open('$pages_file') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        page = json.loads(line)
        items.extend(page.get('data', []))
print(json.dumps({'data': items}))
")
  rm -f "$pages_file"

  # Validate JSON
  if ! echo "$response" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    log "ERROR: Invalid JSON response from $label"
    return
  fi

  # Extract and save each workflow
  local count
  count=$(echo "$response" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))")

  if [ "$count" = "0" ]; then
    log "  $label: no workflows found"
    return
  fi

  log "  $label: $count workflows found, exporting..."

  echo "$response" | python3 -c "
import sys, json, os

data = json.load(sys.stdin)
workflows = data.get('data', [])

for w in workflows:
    wid = w.get('id', 'unknown')
    name = w.get('name', 'unnamed')
    # Print: id|name|json (one line per workflow)
    print(json.dumps({'id': wid, 'name': name, 'workflow': w}))
" | while IFS= read -r line; do
    local wf_name wf_id target_dir safe_name filepath

    wf_name=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
    wf_id=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

    target_dir=$(route_workflow "$wf_name")
    safe_name=$(sanitize_name "$wf_name")
    filepath="$target_dir/${safe_name}.json"

    # BUG-20260908-001 (Olaf, 2026-09-08): capture the OLD staticData.global size
    # before we overwrite the file, so we can detect a collapse after writing.
    # See the ALERT block below for why this exists.
    old_static_size=0
    if [ -f "$filepath" ]; then
      old_static_size=$(python3 -c "
import json
try:
    with open('$filepath') as f:
        d = json.load(f)
    print(len(json.dumps(d.get('staticData', {}).get('global', {}))))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
    fi

    # Write pretty-printed JSON
    echo "$line" | python3 -c "
import sys, json
data = json.load(sys.stdin)['workflow']
# Remove volatile fields that change on every export (createdAt, updatedAt, versionId)
for key in ['updatedAt', 'versionId', 'statistics']:
    data.pop(key, None)
print(json.dumps(data, indent=2, ensure_ascii=False))
" > "$filepath"

    # BUG-20260908-001 (Olaf, 2026-09-08): alert on a sudden staticData.global
    # collapse instead of silently committing it as a routine backup diff.
    #
    # 2026-09-08 incident: R4G_BrokerSync_v1's staticData.global went
    # 373KB -> 70B (22 brokerPasswords, 7 brokerRows, 15 brokerCredits, 71
    # nettingLog, 71 accountAudit, 5 accountRevocations, 12 nettingResults all
    # zeroed to the Code node's own init-default) and R4G_Credit_Save's
    # adminKey emptied, in the SAME nightly backup run that had exported full
    # data the day before. The backup script itself did nothing wrong — it
    # honestly recorded the live server's state — but it committed a 24853
    # deletion / 211 insertion diff without a single warning line, so the loss
    # sat undiscovered until Gale happened to look at the diff stat by hand.
    # A cheap size-ratio check here would have turned that into an immediate
    # Telegram page instead of a silent commit.
    #
    # Threshold: only fires above a 2KB floor (skips tiny/empty workflows
    # where noise is common and the blast radius is negligible) and only on a
    # >70% drop (a normal purge/cleanup operation can legitimately shrink
    # state by a smaller amount; 70%+ on a workflow that already held >2KB is
    # the "went to (near) zero" shape this incident actually had).
    new_static_size=$(python3 -c "
import json
try:
    with open('$filepath') as f:
        d = json.load(f)
    print(len(json.dumps(d.get('staticData', {}).get('global', {}))))
except Exception:
    print(0)
" 2>/dev/null || echo 0)

    if [ "$old_static_size" -gt 2000 ] 2>/dev/null; then
      collapsed=$(python3 -c "print(1 if $new_static_size < $old_static_size * 0.3 else 0)" 2>/dev/null || echo 0)
      if [ "$collapsed" = "1" ]; then
        alert_msg="🔴 [n8n-backup] staticData COLLAPSE: '${wf_name}' (${wf_id}) went ${old_static_size}B -> ${new_static_size}B staticData.global in one backup run. Possible live data loss on 10.128.0.5 — do NOT assume this is a normal purge until checked. See scripts/backup-n8n-workflows.sh BUG-20260908-001 note."
        log "ALERT: $alert_msg"
        bot_token=$(grep "TELEGRAM_BOT_TOKEN" "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2)
        if [ -n "$bot_token" ]; then
          curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
            -d "chat_id=6655962301" \
            --data-urlencode "text=${alert_msg}" > /dev/null 2>&1
        else
          log "ALERT: no TELEGRAM_BOT_TOKEN in $PROJECT_ROOT/.env, could not page — see log line above"
        fi
      fi
    fi

    TOTAL_EXPORTED=$((TOTAL_EXPORTED + 1))
  done

  log "  $label: exported $count workflows"
}

# ── Main ──
log "=== n8n Workflow Backup ==="

for server_def in "${SERVERS[@]}"; do
  IFS='|' read -r label host key_file <<< "$server_def"
  export_from_server "$label" "$host" "$key_file"
done

log "Total exported: files written to projects/*/workflows/"

# ── Git commit if there are changes ──
# Each project may have its own git repo (submodule), so commit in each separately.
# Fall back to main repo if project dir has no .git of its own.

commit_workflows() {
  local dir="$1"
  local label="$2"

  [ -d "$dir" ] || return

  # Find the git repo that owns this directory
  local git_root
  git_root=$(cd "$dir" && git rev-parse --show-toplevel 2>/dev/null) || git_root="$PROJECT_ROOT"

  # NOTE (2026-09-03, BUG found by Gale, fixed by Olaf): $dir is the LOGICAL
  # path (e.g. /home/alexey/banda/projects/r4g/workflows, reached through a
  # bind mount), while `git rev-parse --show-toplevel` resolves symlinks and
  # returns the PHYSICAL path (/home/alexey/openclaw-workspaces/shared/...).
  # os.path.relpath() on the raw logical $dir against the physical $git_root
  # produced garbage like "../../../../banda/projects/r4g/workflows", which
  # made every `git status`/`git add` below silently fail as "outside
  # repository" (swallowed by 2>/dev/null || true) — the script reported
  # "no changes" every single run since 2026-07-26, for every project, while
  # workflow JSON kept drifting from git HEAD uncommitted. Fix: resolve $dir
  # to its physical path FIRST, then take relpath against $git_root (also
  # physical) — the two now agree. Stopped swallowing git status's stderr so
  # a real "outside repository" failure is visible in the log instead of
  # looking identical to "no changes".
  local dir_real
  dir_real=$(realpath "$dir")

  local rel_path
  rel_path=$(python3 -c "import os; print(os.path.relpath('$dir_real', '$git_root'))")

  cd "$git_root"

  local changed status_err
  status_err=$(mktemp)
  if ! changed=$(git status --porcelain "$rel_path" 2>"$status_err"); then
    log "Git ($label): ERROR git status failed: $(cat "$status_err")"
    rm -f "$status_err"
    return
  fi
  rm -f "$status_err"

  if [ -n "$changed" ]; then
    local count
    count=$(echo "$changed" | wc -l | tr -d ' ')
    log "Git ($label): $count workflow file(s) changed in $git_root"

    if ! git add "$rel_path" 2>&1; then
      log "Git ($label): ERROR git add failed"
      return
    fi
    R4G_ALLOW_N8N_EXPORT=1 git commit -m "backup: $label n8n workflows export $(date '+%Y-%m-%d %H:%M UTC')

Auto-exported $count workflow(s) from n8n servers.
" || log "Git ($label): commit failed (permissions or no changes)"
  else
    log "Git ($label): no changes"
  fi
}

commit_workflows "$R4G_DIR" "r4g"
commit_workflows "$LIMO_DIR" "limo"
commit_workflows "$FAM_DIR" "fam"
commit_workflows "$AGENTPM_DIR" "agentpm"
commit_workflows "$IPA_DIR" "ipa"

log "=== Backup complete ==="
