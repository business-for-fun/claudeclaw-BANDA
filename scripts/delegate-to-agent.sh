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
#
# Enforcement V2 (2026-07-30): универсальный, per-card гейты + пауза.
#   - Конфиги проектов: store/enforce/<project>.conf (MODE=warn|enforce).
#   - Проектная делегация обязана содержать BUG-/TASK-/FEAT-ID карточки.
#   - store/PAUSE_ALL → блок всего; store/PAUSE_<PROJECT> → блок проекта.
#     Паузы всегда enforced; "allow: <ID>" внутри файла — исключения.
#   - DELEGATE_DRY_RUN=1 — прогнать гарды без реальной делегации.
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

# Детерминированная локаль: кириллица в regex'ах конфигов не должна зависеть
# от окружения вызывающего (инцидент: "Invalid collation character" тихо
# превращал матч в не-матч и отключал детект проекта).
export LC_ALL=C.UTF-8

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

  # PAUSE gate для parallel-режима: per-card гарды тут не применяются
  # (JSON парсить в bash хрупко), поэтому при активной паузе параллельные
  # делегации блокируются целиком, без allow-исключений.
  PAR_STORE="$SCRIPT_DIR/../store"
  if [ -f "$PAR_STORE/PAUSE_ALL" ]; then
    echo "🛑 GLOBAL PAUSE (PAUSE_ALL) — parallel-делегация заблокирована." >&2
    sed 's/^/   /' "$PAR_STORE/PAUSE_ALL" >&2
    exit 6
  fi
  for par_pause in "$PAR_STORE"/PAUSE_*; do
    [ -e "$par_pause" ] || continue
    par_project="$(basename "$par_pause" | sed 's/^PAUSE_//' | tr '[:upper:]' '[:lower:]')"
    par_conf="$SCRIPT_DIR/../store/enforce/${par_project}.conf"
    par_regex=""
    [ -f "$par_conf" ] && par_regex="$(grep -m1 '^DETECT_REGEX=' "$par_conf" | cut -d= -f2- | tr -d \'\")"
    if { [ -n "$par_regex" ] && echo "$TASKS_JSON" | grep -qiE "$par_regex"; } \
       || echo "$TASKS_JSON" | grep -qi "$par_project"; then
      echo "🛑 PAUSE ACTIVE [$par_project] — parallel-делегация заблокирована целиком." >&2
      sed 's/^/   /' "$par_pause" >&2
      echo "Для разрешённых карточек используй одиночные делегации (allow: работает только там)." >&2
      exit 6
    fi
  done
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

# ═══════════════════════════════════════════════════════════════════
# Enforcement V2 (2026-07-30) — универсальный, для ВСЕХ проектов.
# Per-card гейты + механическая пауза. Конфиги: store/enforce/<project>.conf
# (PROJECT, PROJECT_DIR, CARDS_DIR, DETECT_REGEX, DEPLOY_REGEX, SYNC_REGEX,
#  CODE_OWNERS, EXECUTORS, VERIFY_AGENTS, MODE=warn|enforce).
#
# Паузы (ставит/снимает ТОЛЬКО Alex; всегда enforced, независимо от MODE):
#   store/PAUSE_ALL          — стоп-кран: блокирует ЛЮБЫЕ делегации
#   store/PAUSE_<PROJECT>    — блокирует делегации одного проекта
#   строки "allow: <CARD-ID>" внутри файла — точечные исключения
#
# Определение проекта: по ID карточки (в чьём CARDS_DIR лежит файл),
# иначе по DETECT_REGEX. Задача вне всех проектов гейтам не подлежит.
# ═══════════════════════════════════════════════════════════════════
ENFORCE_DIR="$SCRIPT_DIR/../store/enforce"
STORE_DIR="$SCRIPT_DIR/../store"
CARD_ID="$(echo "$PROMPT" | grep -oE '(BUG|TASK|FEAT)-20[0-9]{6}-[0-9]{3}' | head -1 || true)"

# ── GATE −1: GLOBAL PAUSE — раньше всего, для любых делегаций ──
if [ -f "$STORE_DIR/PAUSE_ALL" ]; then
  if [ -n "$CARD_ID" ] && grep -q "^allow: $CARD_ID" "$STORE_DIR/PAUSE_ALL"; then
    echo "ℹ️  PAUSE_ALL active, but $CARD_ID is explicitly allowed." >&2
  else
    echo "🛑 GLOBAL PAUSE (PAUSE_ALL) — все делегации заблокированы." >&2
    sed 's/^/   /' "$STORE_DIR/PAUSE_ALL" >&2
    echo "Паузу снимает ТОЛЬКО Alex. Разрешено: отвечать в чат и ждать." >&2
    exit 6
  fi
fi

# ── Определение проекта ──
MATCHED_CONF=""
CARD_FILE=""
load_conf() { # sets PROJECT, PROJECT_DIR, CARDS_DIR, regexes, owners, MODE
  PROJECT=""; PROJECT_DIR=""; CARDS_DIR=""; DETECT_REGEX=""; DEPLOY_REGEX=""
  SYNC_REGEX=""; CODE_OWNERS=""; EXECUTORS=""; VERIFY_AGENTS=""; MODE="warn"
  # shellcheck disable=SC1090
  . "$1"
}
if [ -d "$ENFORCE_DIR" ]; then
  if [ -n "$CARD_ID" ]; then
    for conf in "$ENFORCE_DIR"/*.conf; do
      [ -e "$conf" ] || continue
      load_conf "$conf"
      if [ -f "$SCRIPT_DIR/../$CARDS_DIR/$CARD_ID.md" ]; then
        MATCHED_CONF="$conf"; CARD_FILE="$SCRIPT_DIR/../$CARDS_DIR/$CARD_ID.md"; break
      fi
    done
  fi
  if [ -z "$MATCHED_CONF" ]; then
    for conf in "$ENFORCE_DIR"/*.conf; do
      [ -e "$conf" ] || continue
      load_conf "$conf"
      if [ -n "$DETECT_REGEX" ] && echo "$PROMPT" | grep -qiE "$DETECT_REGEX"; then
        MATCHED_CONF="$conf"; break
      fi
    done
  fi
fi

if [ -z "$MATCHED_CONF" ]; then
  # чистим leftover-переменные последнего load_conf из циклов детекта
  PROJECT=""; MODE=""
fi

if [ -n "$MATCHED_CONF" ] && [ -f "$DB_PATH" ]; then
  load_conf "$MATCHED_CONF"
  PROJECT_UPPER="$(echo "$PROJECT" | tr '[:lower:]' '[:upper:]')"
  PAUSE_FILE="$STORE_DIR/PAUSE_${PROJECT_UPPER}"
  TAG="ENFORCEMENT[$PROJECT]"

  violation() { # $1 = message, $2 = hint
    echo "🚫 $TAG: $1" >&2
    [ -n "${2:-}" ] && echo "   $2" >&2
    if [ "$MODE" = "enforce" ]; then
      exit 6
    else
      echo "   [WARN-MODE ($PROJECT): делегация пропущена, в enforce был бы блок]" >&2
    fi
  }

  # ── GATE 0: PROJECT PAUSE — always enforced ──
  if [ -f "$PAUSE_FILE" ]; then
    if [ -n "$CARD_ID" ] && grep -q "^allow: $CARD_ID" "$PAUSE_FILE"; then
      echo "ℹ️  PAUSE active for $PROJECT, but $CARD_ID is explicitly allowed:" >&2
      grep "^allow: $CARD_ID" "$PAUSE_FILE" >&2
    else
      echo "🛑 PAUSE ACTIVE [$PROJECT] — делегация заблокирована." >&2
      sed 's/^/   /' "$PAUSE_FILE" >&2
      echo "Пауза снимается ТОЛЬКО Alex (удаление файла $PAUSE_FILE)." >&2
      echo "Никакие события, уведомления и пинки её не отменяют. Разрешено: отвечать в чат." >&2
      exit 6
    fi
  fi

  # ── GATE 1: card required (Rule 1) ──
  if [ -z "$CARD_ID" ]; then
    violation "Задача проекта $PROJECT без ID карточки в промпте." \
      "Каждая делегация обязана содержать BUG-/TASK-/FEAT-ID. Нет карточки → сначала открой её в $CARDS_DIR/ (Rule 1)."
  elif [ -z "$CARD_FILE" ]; then
    violation "Карточка $CARD_ID не найдена ни в одном проекте (искали по всем CARDS_DIR)." \
      "Открой карточку в $CARDS_DIR/ до делегации (Rule 1)."
  else
    # ── GATE 2: card is open ──
    CARD_STATUS="$(grep -m1 -oP '^\*\*Status:\*\*\s*\K\S+' "$CARD_FILE" 2>/dev/null || true)"
    case "$CARD_STATUS" in
      closed|rejected)
        violation "Карточка $CARD_ID имеет статус '$CARD_STATUS' — работа по ней закрыта." \
          "Новая проблема → новая карточка."
        ;;
    esac

    # ── GATE 3: duplicate step for this card (exact, not similarity) ──
    DUP_TASK=$(sqlite3 "$DB_PATH" "
      SELECT id || ' → ' || to_agent || ' (' || status || ', ' || created_at || ')'
      FROM inter_agent_tasks
      WHERE status IN ('pending','accepted','in_progress')
        AND prompt LIKE '%$CARD_ID%'
      LIMIT 1;" 2>/dev/null || true)
    if [ -n "$DUP_TASK" ]; then
      violation "По карточке $CARD_ID уже есть активная задача: $DUP_TASK" \
        "Шаг уже в полёте — дождись завершения, не дублируй (инцидент «двойной smoke» 30.07)."
    fi

    # ── GATE 4: step order per project pipeline ──
    completed_for_card() { # $1 = sql agent list "'a','b'"
      sqlite3 "$DB_PATH" "
        SELECT count(*) FROM inter_agent_tasks
        WHERE to_agent IN ($1) AND status='completed'
          AND prompt LIKE '%$CARD_ID%';" 2>/dev/null || echo 0
    }

    if [ -n "$DEPLOY_REGEX" ] && echo "$PROMPT" | grep -qiE "$DEPLOY_REGEX"; then
      # Необратимое действие (деплой/релиз/покупка) → approval в карточке (Rule 6)
      if ! grep -qiE 'approved_by:\s*[^ <]|approved to deploy|approve[d]? .*(alex|valera|валер|fedor|фёдор|batch)' "$CARD_FILE"; then
        violation "Необратимое действие по $CARD_ID без зафиксированного approval в карточке (Rule 6)." \
          "Впиши в карточку approved_by: <кто> (или цитату approve) — потом делегируй."
      fi
    elif [ -n "$SYNC_REGEX" ] && echo "$PROMPT" | grep -qiE "$SYNC_REGEX"; then
      # Синк/доставка кода → шаг владельца кода по карточке должен быть завершён
      if [ -n "$CODE_OWNERS" ] && [ "$(completed_for_card "$CODE_OWNERS")" -eq 0 ]; then
        violation "Синк по $CARD_ID раньше завершённого фикса владельца кода." \
          "Порядок: fix ($CODE_OWNERS) → sync. Откаты оформляй отдельной карточкой."
      fi
    fi

    if [ -n "$VERIFY_AGENTS" ] && echo " $VERIFY_AGENTS " | grep -q " $AGENT_ID " \
       && echo "$PROMPT" | grep -qiE "verif|верифик|провер|smoke"; then
      if [ -n "$EXECUTORS" ] && [ "$(completed_for_card "$EXECUTORS")" -eq 0 ]; then
        violation "Верификация по $CARD_ID раньше какого-либо завершённого шага исполнителя." \
          "Порядок: fix → (sync/deploy) → verify."
      fi
    fi
  fi

  # ── GATE 5: uncommitted CODE перед деплоем/синком (доки .md не блокируют) ──
  if [ -n "$PROJECT_DIR" ] && [ -d "$SCRIPT_DIR/../$PROJECT_DIR/.git" ] \
     && echo "$PROMPT" | grep -qiE "${DEPLOY_REGEX:-__none__}|${SYNC_REGEX:-__none__}"; then
    UNCOMMITTED_CODE=$(git -C "$SCRIPT_DIR/../$PROJECT_DIR" status --porcelain 2>/dev/null \
      | grep -vE '(\.md$|^\?\? )' | grep -E '\.(js|jsx|ts|json|sh|css)$' | head -3 || true)
    if [ -n "$UNCOMMITTED_CODE" ]; then
      violation "Незакоммиченный КОД в $PROJECT перед синком/деплоем:" \
        "$UNCOMMITTED_CODE"
    fi
  fi
  # (Апрельский auto-push удалён: push — часть деплой-скрипта, не побочный эффект.)
fi

# ── Dry-run: прогнать гарды без реальной делегации (для тестов) ──
if [ "${DELEGATE_DRY_RUN:-}" = "1" ]; then
  echo "DRY-RUN OK: guards passed (project=${PROJECT:-none}, mode=${MODE:-n/a}), would delegate to '$AGENT_ID'" >&2
  exit 0
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
