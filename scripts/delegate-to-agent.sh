#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# delegate-to-agent.sh — Делегация задачи РЕАЛЬНОМУ агенту через оркестратор
#
# Вызывает daemon API (POST /api/delegate) который загружает CLAUDE.md агента,
# запускает на его модели (Haiku/Sonnet/Opus), отправляет Telegram от его бота,
# логирует в hive_mind и inter_agent_tasks.
#
# Usage:
#   delegate-to-agent.sh <agent_id> "prompt text" [timeout_ms]
#   delegate-to-agent.sh --parallel '<json_tasks>' [timeout_ms]
#
# Single agent:
#   delegate-to-agent.sh tuco "Найди 5 новостей про AI за сегодня"
#   delegate-to-agent.sh lalo "Напиши пост на основе: ..." 300000
#   delegate-to-agent.sh gale "Сделай code review файла src/bot.ts"
#
# Parallel (JSON):
#   delegate-to-agent.sh --parallel '[
#     {"agentId":"tuco","prompt":"Найди новости"},
#     {"agentId":"lalo","prompt":"Напиши пост"}
#   ]'
#
# Agents:
#   tuco  — Туко Саламанка (Haiku) — быстрый исполнитель рутины
#   lalo  — Лало Саламанка (Sonnet) — маркетолог-расследователь
#   gale  — Гейл Беттикер (Opus) — программист-перфекционист
#   kim   — Ким Уэксслер (Sonnet) — юрист, ОТК, документы
#
# Returns: agent's response text (stdout), exit code 0 on success
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env not found at $ENV_FILE" >&2
  exit 1
fi

# Read config from .env
DASHBOARD_TOKEN=$(grep -E '^DASHBOARD_TOKEN=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
DASHBOARD_PORT=$(grep -E '^DASHBOARD_PORT=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || echo "3142")

if [ -z "$DASHBOARD_PORT" ]; then
  DASHBOARD_PORT=3142
fi

if [ -z "$DASHBOARD_TOKEN" ]; then
  echo "ERROR: DASHBOARD_TOKEN not found in .env" >&2
  exit 1
fi

BASE_URL="http://localhost:${DASHBOARD_PORT}"

# ── Parallel mode ──
if [ "${1:-}" = "--parallel" ]; then
  TASKS_JSON="${2:-}"
  # NOTE: 90-min default conflicts with async-first guidance in CLAUDE.md.
  # Long tasks (builds, deploys, tests) MUST pass run_in_background=true to
  # the orchestrator. Sync callers that hit this default will block for 90 min.
  TIMEOUT_MS="${3:-5400000}"

  if [ -z "$TASKS_JSON" ]; then
    echo "Usage: delegate-to-agent.sh --parallel '<json_tasks>' [timeout_ms]" >&2
    exit 1
  fi

  # Build request body
  BODY=$(cat <<EOJSON
{"tasks":${TASKS_JSON},"timeoutMs":${TIMEOUT_MS}}
EOJSON
)

  RESPONSE=$(curl -s -X POST \
    "${BASE_URL}/api/delegate/parallel?token=${DASHBOARD_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    --max-time $((TIMEOUT_MS / 1000 + 30)))

  # Check if response is valid JSON
  if ! echo "$RESPONSE" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    echo "ERROR: Invalid response from daemon. Is it running?" >&2
    echo "$RESPONSE" >&2
    exit 1
  fi

  # Check ok field
  OK=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok', False))")
  if [ "$OK" != "True" ]; then
    ERROR=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error', 'Unknown error'))")
    echo "ERROR: $ERROR" >&2
    exit 1
  fi

  # Output full JSON results (caller parses what they need)
  echo "$RESPONSE"
  exit 0
fi

# ── Single agent mode ──
AGENT_ID="${1:-}"
PROMPT="${2:-}"
# NOTE: 90-min default — long tasks MUST use run_in_background=true (see CLAUDE.md).
TIMEOUT_MS="${3:-5400000}"

if [ -z "$AGENT_ID" ] || [ -z "$PROMPT" ]; then
  echo "Usage: delegate-to-agent.sh <agent_id> \"prompt\" [timeout_ms]" >&2
  echo "       delegate-to-agent.sh --parallel '<json_tasks>' [timeout_ms]" >&2
  echo "" >&2
  echo "Agents: tuco (Haiku), lalo (Sonnet), gale (Opus), kim (Sonnet)" >&2
  exit 1
fi

# Validate agent_id
case "$AGENT_ID" in
  tuco|lalo|gale|kim|olaf|rob|freddie) ;; # known agents
  *)
    echo "WARNING: Agent '$AGENT_ID' may not exist. Known: tuco, lalo, gale, kim" >&2
    ;;
esac

# ── Duplicate delegation guard ──
# Check if this agent already has an active task in the last 30 minutes.
# (widened from 10 on 2026-07-30: a duplicate smoke delegation slipped through a 10:04 gap)
# Warns the coordinator to avoid wasting tokens on duplicate/rephrased delegations.
DB_PATH="$SCRIPT_DIR/../store/claudeclaw.db"
if [ -f "$DB_PATH" ]; then
  ACTIVE_TASK=$(sqlite3 "$DB_PATH" "
    SELECT id, substr(prompt, 1, 120), status, created_at
    FROM inter_agent_tasks
    WHERE to_agent = '$AGENT_ID'
      AND status IN ('pending', 'accepted', 'in_progress')
      AND created_at >= datetime('now', '-30 minutes')
    ORDER BY created_at DESC
    LIMIT 1;
  " 2>/dev/null)

  if [ -n "$ACTIVE_TASK" ]; then
    # Parse fields (sqlite3 default separator is |)
    TASK_ID=$(echo "$ACTIVE_TASK" | cut -d'|' -f1)
    TASK_PROMPT=$(echo "$ACTIVE_TASK" | cut -d'|' -f2)
    TASK_STATUS=$(echo "$ACTIVE_TASK" | cut -d'|' -f3)
    TASK_TIME=$(echo "$ACTIVE_TASK" | cut -d'|' -f4)

    echo "" >&2
    echo "⚠️  WARNING: DUPLICATE DELEGATION DETECTED" >&2
    echo "   Agent '$AGENT_ID' already has an active task (status: $TASK_STATUS, started: $TASK_TIME):" >&2
    echo "   \"$TASK_PROMPT...\"" >&2
    echo "   Task ID: $TASK_ID" >&2
    echo "" >&2
    echo "   Sending the same task again wastes tokens. WAIT for the current task to finish." >&2
    echo "   If you are CERTAIN this is a different task, the delegation will proceed anyway." >&2
    echo "" >&2
  fi
fi

# ── R4G Workflow Enforcement ──
# Ensures strict Gale → Freddie → Kim sequence for R4G project tasks.
# Blocks out-of-order delegations and enforces git commit + push before deploy.
R4G_DIR="$SCRIPT_DIR/../projects/r4g"

is_r4g_task() {
  echo "$PROMPT" | grep -qiE "r4g|netting|frontend|firebase|business-for-fun|Bug #[0-9]|ML Chain|Missing Link|SWAP|broker console|NettingResults|BrokerConsole|Settings\.jsx|App\.jsx"
}

if is_r4g_task && [ -f "$DB_PATH" ]; then
  case "$AGENT_ID" in
    freddie|olaf)
      # RULE 1: Cannot deploy without Gale's commit first
      LAST_GALE=$(sqlite3 "$DB_PATH" "
        SELECT status, completed_at FROM inter_agent_tasks
        WHERE to_agent = 'gale' AND status = 'completed'
        ORDER BY completed_at DESC LIMIT 1;
      " 2>/dev/null)
      if [ -z "$LAST_GALE" ]; then
        echo "🚫 R4G WORKFLOW VIOLATION: Cannot deploy without Gale's commit!" >&2
        echo "   Workflow: Gale (fix+commit) → Freddie (deploy) → Kim (verify)" >&2
        exit 6
      fi

      # RULE 2: Git commit must exist before deploy
      if [ -d "$R4G_DIR/.git" ]; then
        UNCOMMITTED=$(git -C "$R4G_DIR" status --porcelain 2>/dev/null | head -1)
        if [ -n "$UNCOMMITTED" ]; then
          echo "🚫 R4G WORKFLOW VIOLATION: Uncommitted changes in R4G!" >&2
          echo "   Gale must commit before deploy. Run: git -C $R4G_DIR status" >&2
          exit 6
        fi
      fi

      # RULE 3: Auto-push to GitHub before deploy
      if [ -d "$R4G_DIR/.git" ]; then
        REMOTE_CHECK=$(git -C "$R4G_DIR" remote get-url origin 2>/dev/null || echo "")
        if [ -n "$REMOTE_CHECK" ]; then
          git -C "$R4G_DIR" push origin master --quiet 2>/dev/null && \
            echo "✅ R4G: auto-pushed to GitHub (business-for-fun/r4g)" >&2 || \
            echo "⚠️  R4G: git push failed, continue with deploy" >&2
        fi
      fi
      ;;

    kim)
      # RULE 4: Cannot verify without deploy first
      LAST_DEPLOY=$(sqlite3 "$DB_PATH" "
        SELECT status, completed_at FROM inter_agent_tasks
        WHERE to_agent IN ('freddie', 'olaf')
        AND status = 'completed'
        AND prompt LIKE '%deploy%'
        ORDER BY completed_at DESC LIMIT 1;
      " 2>/dev/null)
      if [ -z "$LAST_DEPLOY" ]; then
        echo "🚫 R4G WORKFLOW VIOLATION: Cannot verify without deploy!" >&2
        echo "   Workflow: Gale (fix+commit) → Freddie (deploy) → Kim (verify)" >&2
        exit 6
      fi
      ;;
  esac
fi

# ── Resolve agent-specific dashboard port ──
resolve_agent_port() {
  local agent_id="$1"
  local agent_yaml="$SCRIPT_DIR/../agents/${agent_id}/agent.yaml"
  if [ -f "$agent_yaml" ]; then
    local port=$(grep -E '^dashboard_port:' "$agent_yaml" | awk '{print $2}' | tr -d '"' | tr -d "'")
    if [ -n "$port" ]; then
      echo "$port"
      return
    fi
  fi
  echo "$DASHBOARD_PORT"
}

AGENT_PORT=$(resolve_agent_port "$AGENT_ID")
AGENT_URL="http://localhost:${AGENT_PORT}"

# Escape prompt for JSON (handle quotes, newlines, backslashes)
ESCAPED_PROMPT=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" <<< "$PROMPT")

# Build request body
BODY="{\"agentId\":\"${AGENT_ID}\",\"prompt\":${ESCAPED_PROMPT},\"timeoutMs\":${TIMEOUT_MS}}"

# Try agent's own dashboard first (3s connect timeout), fallback to main
RESPONSE=$(curl -s --connect-timeout 3 -X POST \
  "${AGENT_URL}/api/delegate?token=${DASHBOARD_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  --max-time $((TIMEOUT_MS / 1000 + 30)) 2>/dev/null)

# If agent unreachable or invalid response, fallback to main dashboard
if [ -z "$RESPONSE" ] || ! echo "$RESPONSE" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  echo "INFO: Agent dashboard unreachable on port $AGENT_PORT, falling back to main ($DASHBOARD_PORT)" >&2
  RESPONSE=$(curl -s -X POST \
    "${BASE_URL}/api/delegate?token=${DASHBOARD_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$BODY" \
    --max-time $((TIMEOUT_MS / 1000 + 30)))
fi

# Check if response is valid JSON
if ! echo "$RESPONSE" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  echo "ERROR: Invalid response from daemon. Is it running on port ${DASHBOARD_PORT}?" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

# Parse response
OK=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok', False))")

if [ "$OK" = "True" ]; then
  # Extract result text
  RESULT_TEXT=$(echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
text = data.get('result', {}).get('text', '')
if text:
    print(text)
else:
    print('[No response from agent]')
")
  DURATION=$(echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ms = data.get('result', {}).get('durationMs', 0)
print(f'{ms/1000:.1f}s')
")

  echo "$RESULT_TEXT"
  echo "" >&2
  echo "--- Agent: $AGENT_ID | Duration: $DURATION ---" >&2
  exit 0
else
  ERROR=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error', 'Unknown error'))")
  echo "ERROR: Delegation to $AGENT_ID failed: $ERROR" >&2
  exit 1
fi
