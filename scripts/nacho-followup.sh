#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# nacho-followup.sh — будильник для Начо (жалоба Валеры 29-30.07:
# «по таймауту улетает и сам не просыпается»).
#
# Начо — событийная система: его будят только входящие сообщения.
# Этот скрипт каждые 5 минут (cron amileev) проверяет завершённые
# делегации в inter_agent_tasks и, если появились новые, шлёт Начо
# «⏰ Follow-up» через его dashboard API. Каждая задача пингуется
# не более одного раза (dedup в state-файле). Токены тратятся
# только когда реально есть что подхватить.
#
# Cron: */5 * * * * bash /home/alexey/banda/scripts/nacho-followup.sh
# ─────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT=/home/alexey/banda
DB="$ROOT/store/claudeclaw.db"
STATE="$ROOT/store/followup-poked.txt"

# Начо лежит — будить некого
systemctl is-active --quiet banda-main || exit 0

TOKEN="$(grep -m1 '^DASHBOARD_TOKEN=' "$ROOT/.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
[ -z "$TOKEN" ] && TOKEN="$(sudo grep -m1 '^DASHBOARD_TOKEN=' "$ROOT/.env" | cut -d= -f2- | tr -d '[:space:]')"
if [ -z "$TOKEN" ]; then
  echo "$(date -u +%FT%TZ) ERROR: DASHBOARD_TOKEN not readable" >&2
  exit 1
fi

touch "$STATE"

# Завершённые за последние 30 минут (окно > интервала крона с запасом)
ROWS="$(sqlite3 -separator '|' "$DB" \
  "SELECT id, to_agent, replace(substr(prompt,1,70), char(10), ' ')
   FROM inter_agent_tasks
   WHERE status='completed'
     AND completed_at >= datetime('now','-30 minutes')
   ORDER BY completed_at;" 2>/dev/null)"

[ -z "$ROWS" ] && exit 0

NEW_IDS=()
LIST=""
while IFS='|' read -r id agent snippet; do
  [ -z "$id" ] && continue
  grep -q "^$id$" "$STATE" && continue
  NEW_IDS+=("$id")
  LIST+="• ${id:0:8} [$agent] $snippet"$'\n'
done <<< "$ROWS"

[ ${#NEW_IDS[@]} -eq 0 ] && exit 0

MSG="⏰ Follow-up (авто, nacho-followup.sh): завершились делегации:
$LIST
Для каждой: возьми result из inter_agent_tasks (sqlite3 store/claudeclaw.db), отчитайся В ТОМ ЧАТЕ, где ставилась задача (для R4G — группа, через curl sendMessage), и продолжи конвейер карточки.
⚠️ ПЕРЕД продолжением конвейера ОБЯЗАТЕЛЬНО проверь, не запущен ли следующий шаг уже: sqlite3 store/claudeclaw.db \"SELECT id,to_agent,substr(prompt,1,50) FROM inter_agent_tasks WHERE status='in_progress';\" — если следующий шаг там, НЕ делегируй его повторно (инцидент 30.07: двойной smoke). Если по какой-то задаче уже отчитался — подтверди одной строкой, отчёт не повторяй."

HTTP=$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
  -X POST "http://127.0.0.1:3141/api/chat/send?token=$TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"message": sys.argv[1]}))' "$MSG")")

if [ "$HTTP" = "200" ]; then
  printf '%s\n' "${NEW_IDS[@]}" >> "$STATE"
  tail -500 "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  echo "$(date -u +%FT%TZ) poked Nacho: ${#NEW_IDS[@]} task(s): ${NEW_IDS[*]}"
else
  echo "$(date -u +%FT%TZ) ERROR: poke failed HTTP $HTTP (tasks: ${NEW_IDS[*]})" >&2
  exit 1
fi
