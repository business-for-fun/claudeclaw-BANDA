#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Сторож бэклога Banda (2026-09-29).
#
# Зачем: Начо заводит карточки, но сам к ним не возвращается — очередь живёт в
# его сессии, а она сбрасывается по нескольку раз в день. Валера обнаруживал
# простой через часы и пинал вручную. Сторож делает этот пинок автоматически.
#
# Что делает: раз в запуск смотрит карточки проекта и находит те, что стоят —
# открыты и по ним давно нет ни одной делегации. Если такие есть, шлёт ОДНО
# короткое сообщение в чат проекта (входит в рабочую сессию Начо, как обычное
# сообщение от человека). Ничего не решает за Начо: он сам выбирает, что
# запускать, что отложить и о чём спросить заказчика.
#
# Запуск: systemd timer banda-backlog-watch.timer (каждые 30 минут).
# Сухой прогон без отправки:  backlog-watch.sh --dry-run
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

BANDA=/home/alexey/banda
DB="$BANDA/store/claudeclaw.db"
STATE="$BANDA/store/backlog-watch.state"
DASH_URL="http://localhost:3141/api/chat/send"

# ── Проекты: <каталог карточек>|<chat_id>|<имя> ──────────────────────────────
# ПУТЬ КАРТОЧЕК НЕ МЕНЯЕТСЯ. Он же зафиксирован в доктрине Начо
# (.claudeclaw/CLAUDE.md, раздел «Бэклог»). Меняешь здесь — меняй и там.
PROJECTS=(
  "/home/alexey/openclaw-workspaces/shared/projects/r4g/cards|-1003759375768|R4G"
)

MIN_IDLE_MIN=120   # карточка «стоит», если по ней нет делегаций столько минут
STALE_DAYS=5       # правило Валеры (29.09): таск старше 5 дней ПРОСРОЧЕН — в работу не брать
MAX_AGE_DAYS=45    # глубина просмотра каталога (для подсчёта просроченных)
COOLDOWN_MIN=60    # не пинать чаще раза в час на проект
STUCK_HOURS=24     # запись задачи в pending/in_progress старше этого = зависшая
MAX_LIST=8         # сколько карточек перечислить в сообщении

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ── Пауза заказчика важнее сторожа ───────────────────────────────────────────
if compgen -G "$BANDA/store/PAUSE_*" > /dev/null; then
  log "пауза активна ($(ls $BANDA/store/PAUSE_* | xargs -n1 basename | tr '\n' ' ')) — молчу"
  exit 0
fi

TOKEN=$(grep '^DASHBOARD_TOKEN=' "$BANDA/.env" | cut -d= -f2- | tr -d '"'"'"' \n')
[ -z "$TOKEN" ] && { log "нет DASHBOARD_TOKEN — выхожу"; exit 1; }

now=$(date +%s)
touch "$STATE"

for entry in "${PROJECTS[@]}"; do
  IFS='|' read -r cards_dir chat_id proj_name <<< "$entry"
  [ -d "$cards_dir" ] || { log "$proj_name: каталог карточек не найден: $cards_dir"; continue; }

  # ── Cooldown: недавно уже пинали ───────────────────────────────────────────
  last=$(grep "^${proj_name}=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2)
  if [ -n "${last:-}" ] && [ $(( (now - last) / 60 )) -lt "$COOLDOWN_MIN" ]; then
    log "$proj_name: пинали $(( (now - last) / 60 )) мин назад — жду"
    continue
  fi

  # ── Кандидаты: открыты и по ним давно нет делегаций ────────────────────────
  stalled=()
  proposed=()
  expired=()
  while IFS= read -r file; do
    key=$(basename "$file" .md)

    # закрытые/отклонённые пропускаем (смотрим шапку карточки)
    if grep -qiE '(^\**(status|статус)\**:?.*(closed|закрыт|rejected|отклон|deploy ok|superseded|дубл|cancell?ed|отмен|wontfix|не актуал|устарел|duplicate|expired|просроч))|(вердикт.*(deploy ok|✅))' "$file"; then
      continue
    fi

    # Точный критерий «стоит в бэклоге»: по карточке НИ РАЗУ не было делегации.
    # Именно на это жалуется заказчик — задание записали и не запустили.
    # Карточки, где работа уже шла (ждут QA, approve, смежную карточку),
    # сторож не трогает: их ведёт сам Начо по своему конвейеру.
    ever=$(sqlite3 "$DB" "SELECT count(*) FROM inter_agent_tasks
           WHERE prompt LIKE '%${key}%';" 2>/dev/null)
    [ "${ever:-0}" != "0" ] && continue

    # и карточка должна отлежаться — даём Начо время запустить её самому
    age_min=$(( (now - $(stat -c %Y "$file")) / 60 ))
    [ "$age_min" -lt "$MIN_IDLE_MIN" ] && continue

    # Возраст задачи считаем по дате В ИМЕНИ карточки (день заведения), а не по
    # mtime: правка статуса не делает просроченный таск свежим.
    d=$(echo "$key" | grep -oE '[0-9]{8}' | head -1)
    if [ -n "$d" ]; then
      age_days=$(( (now - $(date -d "${d:0:4}-${d:4:2}-${d:6:2}" +%s 2>/dev/null || echo "$now")) / 86400 ))
    else
      age_days=0
    fi

    if [ "$age_days" -gt "$STALE_DAYS" ]; then
      expired+=("$key")          # правило Валеры: в работу не брать
    else
      # 2026-10-19: кто завёл карточку. Заказчик (Валера/Alex) — зовём в работу.
      # Побочная находка агента — это ПРЕДЛОЖЕНИЕ, его нельзя запускать само:
      # за неделю 12-19.10 такие съели 30 % ресурса команды, Валера их не ставил.
      OWNER_RE='Valera|Валер|Alex|Алекс|StVallery|Fedor|Федор'
      if head -8 "$file" | grep -qiE "Reporter:?\**[^|]{0,40}($OWNER_RE)"; then
        stalled+=("$key")
      else
        proposed+=("$key")
      fi
    fi
  done < <(find "$cards_dir" -maxdepth 1 -name '*.md' -mtime -"$MAX_AGE_DAYS" 2>/dev/null | sort)

  # ── Зависшие записи задач ──────────────────────────────────────────────────
  # Процесс агента умер (OOM/рестарт), а строка осталась pending/in_progress
  # навсегда — и держит свою карточку: queue-guard видит «активный шаг» и не
  # даёт переделегировать. Прецеденты: Gale 18.09 (6 ч простоя), уборка 16 сирот
  # 30.09. Живые задачи не трогаем — только старше STUCK_HOURS.
  stuck_ids=$(sqlite3 "$DB" "SELECT substr(id,1,8) FROM inter_agent_tasks
              WHERE status IN ('pending','in_progress')
                AND created_at < datetime('now', '-${STUCK_HOURS} hours')
              ORDER BY created_at LIMIT 10;" 2>/dev/null | tr '\n' ' ')
  stuck_count=$(sqlite3 "$DB" "SELECT count(*) FROM inter_agent_tasks
                WHERE status IN ('pending','in_progress')
                  AND created_at < datetime('now', '-${STUCK_HOURS} hours');" 2>/dev/null)

  count=${#stalled[@]}
  prop_count=${#proposed[@]}
  exp_count=${#expired[@]}
  if [ "$count" -eq 0 ] && [ "$prop_count" -eq 0 ] && [ "$exp_count" -eq 0 ] && [ "${stuck_count:-0}" -eq 0 ]; then
    log "$proj_name: бэклог пуст — молчу"
    continue
  fi

  if [ "$count" -gt 0 ]; then
    list=$(printf '%s, ' "${stalled[@]:0:$MAX_LIST}" | sed 's/, $//')
    [ "$count" -gt "$MAX_LIST" ] && list="$list и ещё $((count - MAX_LIST))"
    head_line="в ${proj_name} ${count} карточек ОТ ЗАКАЗЧИКА заведено, но ни разу не запущено — ${list}. По КАЖДОЙ сначала проверь, не сделана ли она уже в рамках другой карточки (поиск по cards/ и git log по затронутым файлам): если да — закрой как duplicate со ссылкой на ту карточку и НЕ делегируй. Что осталось и готово — запусти; что ждёт заказчика, другую карточку или решение — опиши одной строкой в поле Status."
  else
    head_line="в ${proj_name} незапущенных карточек от заказчика нет."
  fi
  if [ "$exp_count" -gt 0 ]; then
    tail_line=" Отдельно: ${exp_count} карточек старше ${STALE_DAYS} дней — по правилу Валеры они ПРОСРОЧЕНЫ, в работу не брать: закрой их статусом expired либо, если задача всё ещё нужна, переспроси заказчика и заведи заново с новой датой."
  else
    tail_line=""
  fi
  if [ "$prop_count" -gt 0 ]; then
    plist=$(printf '%s, ' "${proposed[@]:0:$MAX_LIST}" | sed 's/, $//')
    [ "$prop_count" -gt "$MAX_LIST" ] && plist="$plist и ещё $((prop_count - MAX_LIST))"
    prop_line=" 💡 Отдельно ${prop_count} карточек — ПРЕДЛОЖЕНИЯ команды (побочные находки агентов, заказчик их не ставил): ${plist}. Их НЕ запускать по этому напоминанию: собери одним сообщением заказчику, что нашли и чего это стоит, и жди его решения. Запускать только то, что он одобрил."
  else
    prop_line=""
  fi
  if [ "${stuck_count:-0}" -gt 0 ]; then
    stuck_line=" ⚠ Ещё ${stuck_count} записей задач висят в pending/in_progress больше суток (${stuck_ids}) — процессы давно умерли, а записи держат свои карточки от повторного запуска. Разбери каждую: пометь запись failed с пояснением и верни карточку в бэклог обычным порядком (дубли, срок годности) либо закрой."
  else
    stuck_line=""
  fi

  msg="🔔 Сторож бэклога: ${head_line}${prop_line}${tail_line}${stuck_line} Это автоматическое напоминание, не задача от человека."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "$proj_name: [dry-run] от заказчика $count → ${list:-—} | предложений ${prop_count:-0} | просрочено $exp_count | зависших записей ${stuck_count:-0} ${stuck_ids}"
    continue
  fi

  resp=$(curl -s -m 20 -X POST "${DASH_URL}?token=${TOKEN}" \
         -H 'Content-Type: application/json' \
         -d "$(python3 -c 'import json,sys; print(json.dumps({"message": sys.argv[1], "chat_id": sys.argv[2]}))' "$msg" "$chat_id")" 2>&1)

  if echo "$resp" | grep -q '"ok":true'; then
    grep -v "^${proj_name}=" "$STATE" > "${STATE}.tmp" 2>/dev/null || true
    echo "${proj_name}=${now}" >> "${STATE}.tmp"
    mv "${STATE}.tmp" "$STATE"
    log "$proj_name: толкнул Начо ($count карточек)"
  else
    log "$proj_name: отправка не удалась: $resp"
  fi
done
