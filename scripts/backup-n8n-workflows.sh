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
SERVERS=(
  "r4g|http://10.128.0.5:5678|$SECRETS_DIR/r4g_n8n_api_key"
  "limo|http://10.128.0.7:5678|$SECRETS_DIR/limo_n8n_api_key"
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

  local response
  response=$(curl -s --connect-timeout 10 --max-time 30 \
    -H "X-N8N-API-KEY: $api_key" \
    "$host/api/v1/workflows" 2>/dev/null) || {
    log "ERROR: Cannot reach $label at $host"
    return
  }

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

    # Write pretty-printed JSON
    echo "$line" | python3 -c "
import sys, json
data = json.load(sys.stdin)['workflow']
# Remove volatile fields that change on every export (createdAt, updatedAt, versionId)
for key in ['updatedAt', 'versionId', 'statistics']:
    data.pop(key, None)
print(json.dumps(data, indent=2, ensure_ascii=False))
" > "$filepath"

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
    git commit -m "backup: $label n8n workflows export $(date '+%Y-%m-%d %H:%M UTC')

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
