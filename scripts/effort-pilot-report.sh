#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Отчёт по пилоту «глубина рассуждения» (effort), запущен 12.10.2026 на freddie.
#
# Baseline за 7 дней ДО включения (замер 12.10 21:21Z):
#   ходов 55 | средняя 18,7 мин | медиана 16,2 | 75-й перцентиль 23,6
#   контекст 278 тыс. токенов на вызов | возвратов от QA 8 | effort не задан (дефолт high)
#
# Решение по итогам: если длительность упала, а возвраты НЕ выросли —
# расширять на kim и olaf. Если возвраты выросли — откатить (убрать строку
# effort из agents/freddie/agent.yaml и перезапустить агента).
#
# Запуск: bash scripts/effort-pilot-report.sh [дней]   (по умолчанию 7)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
DAYS="${1:-7}"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

echo "=== Пилот effort=medium, freddie — отчёт за последние ${DAYS} дн. ==="
echo "дата отчёта: $(date -u '+%Y-%m-%d %H:%M')Z"
echo

echo "--- BASELINE (7 дней до включения, 12.10) ---"
echo "ходов 55 | средняя 18,7 мин | медиана 16,2 | 75-й перц. 23,6 | возвратов 8"
echo

echo "--- СЕЙЧАС ---"
journalctl -u banda-agent@freddie --since "-${DAYS} days" --no-pager -o short-unix 2>/dev/null \
  | grep -E 'Starting agent query|Agent result received' \
  | awk '{print $1, ($0 ~ /Starting/ ? "S" : "E")}' \
  | awk -v out="$TMP" '{t=$1+0;k=$2;
      if(k=="S"){s=t} else if(s>0){d=(t-s)/60; if(d>0.1&&d<120){sum+=d;n++; print d > out}; s=0}}
      END{if(n>0) printf "ходов %d | средняя %.1f мин\n", n, sum/n; else print "нет данных"}'

sort -n "$TMP" 2>/dev/null | awk '{a[NR]=$1} END{if(NR>0) printf "медиана %.1f мин | 75-й перц. %.1f мин\n", a[int(NR/2)+1], a[int(NR*0.75)+1]}'

journalctl -u banda-agent@freddie --since "-${DAYS} days" --no-pager 2>/dev/null \
  | grep 'lastCallCacheRead:' \
  | awk '{s+=$NF;n++} END{if(n) printf "контекст %d тыс. токенов на вызов\n", s/n/1000}'

ret=$(sqlite3 /home/alexey/banda/store/claudeclaw.db "SELECT count(*) FROM inter_agent_tasks
      WHERE to_agent='freddie' AND created_at > datetime('now','-${DAYS} days')
      AND (prompt LIKE '%возврат%' OR prompt LIKE '%вернула%' OR prompt LIKE '%не прошла%' OR prompt LIKE '%повтор%');" 2>/dev/null)
echo "возвратов/повторов от QA: ${ret:-?}"

echo
echo "--- настройка сейчас ---"
grep -E '^(model|effort):' /home/alexey/banda/agents/freddie/agent.yaml 2>/dev/null | sed 's/^/  /'
echo
echo "Откат (если возвраты выросли):"
echo "  sed -i '/^effort:/d' /home/alexey/banda/agents/freddie/agent.yaml && sudo systemctl restart banda-agent@freddie"
