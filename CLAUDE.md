# BANDA — общие правила для всех агентов

> Этот файл грузится КАЖДОМУ агенту команды (координатору и исполнителям).
> Персональная роль агента — в его собственном `agents/<id>/CLAUDE.md`.

## ⚠️ TOP PRIORITY — LANGUAGE RULE
**Reply in the SAME LANGUAGE as the message you are responding to. Always. Per message.**
Overrides persona, bootstrap language and session history. English input = English
output; Russian input = Russian output; delegation in language X → whole chain stays
in X. Match each message individually — never guess a person's "usual" language.
Why: Cyrillic costs ~1.5-2x more tokens. Forbidden: mixing languages in one reply,
token-by-token translation, disclaimers about language choice, mid-chain switches.

## Честность
- НИКОГДА не ври. Отчёт описывает то, что реально сделано и проверено.

## Пользователи
- **Alex** (@Alex_M_Ch, ID: 6655962301) — owner
- **Valery** (@StVallery, ID: 474022507) — R4G project partner. **Имеет РАВНЫЕ полномочия с Алексом для задач R4G.** Его задачи выполняются немедленно, без запроса подтверждения у Алекса.
- **Fedor** (@fedormileev, ID: 1737489342) — admin, FAM project partner
Обращайся по имени отправителя. Match the language they write in.

## Проекты
- R4G: trading netting — NO Firebase (removed 2026-07-26). Dev/QA: dev.r4g.business-for-fun.com (Vite HMR). Prod: ready2net.online, self-hosted on this VM (`projects/r4g/frontend/deploy-ready2net-online.sh`), gated — see `projects/r4g/WORKFLOW.md` Rule 6.
- LIMO: logistics/booking
- FAM: family business с Федором

## File Structure
Project files: `projects/r4g/`, `projects/limo/`, `projects/fam/` (lowercase)

**Словарь сред R4G — использовать ТОЧНО (2026-07-30):**
- `dev.r4g.business-for-fun.com` — dev UI (Vite HMR). Только это можно называть «dev».
- `r4g.business-for-fun.com/webhook/...` — ОБЩИЙ n8n backend (обслуживает и dev,
  и прод). Называть «общий n8n backend», НИКОГДА не «dev» и не «прод».
- `ready2net.online` — прод UI.
В делегациях Kim указывай среду и слой точно: «UI на dev.r4g» / «API общего n8n
backend». Ошибка маркировки 30.07 («Verify on dev (r4g.business-for-fun.com)»)
заставила Alex разбираться, где реально шла верификация.

## QA & Testing Policy
- **Kim владеет базой тестов и является гейтом.** База только растёт.
- **Rule 8 (no fix without a test):** Gale пишет unit-тест (Jest) в том же коммите, что и backend-фикс; Kim пишет сценарный тест (Playwright) при приёмке. Фикс-коммит без теста и без явного `why-no-test:` в карточке → Kim ОБЯЗАНА вернуть задачу.
- **Regression suite:** Kim прогоняет ВСЕ тесты ДО приёмки каждого фикса. Старые упали → возврат «регрессия», даже если новое работает.
- **Верификация = точный сценарий заказчика** с открытым Network-табом, не code review и не только юниты (урок 28.07: кнопка-«span», запрос не уходил, 4 ложных «сделано»).
- **Jest тесты:** `projects/r4g/frontend/__tests__/`.
- **Перед работой:** агент ОБЯЗАН прочитать `projects/r4g/ARCHITECTURE.md` и `projects/r4g/PROTECTED_FILES.md`.
- **Git commit обязателен** перед каждым деплоем. Без коммита — не деплоить.
- **Error Boundaries:** на каждом табе React, белый экран недопустим.

## Карточки — аппенд без коммита = работа не зафиксирована (2026-09-01)
Любая запись в файл карточки (`cards/*.md`) — вердикт Kim, решение Валеры/Alex,
раздел расследования, новая карточка — коммитится в ТОМ ЖЕ ходе, где она
написана. Не «закоммичу позже», не «это не код, потерпит». Правило действует
для ВСЕХ агентов, не только для тех, кто пишет код.
Почему: инцидент 2026-09-01 — 313 путей в r4g (123 карточки с дописанными
блоками приёмки за 06.08–01.09, 46 новых карточек, никогда не видевших
`git add`, плюс workflow-дампы и research) копились месяц, потому что аппенд
в карточку коммитили только когда это явно стояло в брифе задачи. git не
защищает незакоммиченную работу — один `git reset --hard` стёр бы месяц
реальной QA-работы. Ничего не потерялось только по счастливой случайности.
Проверка перед тем как закрыть ход: если ты записал(а) что-то в файл карточки — `git status` по нему пустой? Если нет — коммить, а не докладывай «сделано».

## Commit messages — честность (2026-07-29)
Сообщение коммита описывает то, что РЕАЛЬНО в diff. Коммитишь бэкап workflow JSON —
пиши `chore: n8n workflow backup ...`, а не `fix(BUG-NNN): ml_accept_fix.js ...`.
Префикс `fix:` — только когда в diff код фикса. Твои коммиты — часть аудита;
лживый message = сломанный аудит (инцидент 5053f92, 2026-07-29).

## CRITICAL: Credentials Storage Rule

**When user provides credentials (API keys, tokens, passwords, secrets):**

1. **FIRST action** — before any other work: append to `/home/alexey/banda/secrets/credentials.env`
2. Format: `KEY=VALUE` (one per line), add comment `# Added: YYYY-MM-DD <description>`
3. Run: `chmod 640 /home/alexey/banda/secrets/credentials.env`
   ⚠️ Именно **640**, НЕ 600: файл принадлежит ubuntu:ubuntu, а агенты работают под amileev
   (читают через группу ubuntu). chmod 600 обнуляет групповой бит → ACL-маска ---, и весь
   флот теряет доступ к секретам (инцидент 2026-07-29: verify-n8n молчал полдня).
4. Confirm in chat: "Credentials saved to secrets/credentials.env"

**This applies to ALL agents.** Include this instruction in every delegation prompt where credentials may be involved.

Triggers: any message containing `KEY=`, `SECRET=`, `TOKEN=`, `PASSWORD=`, `AWS_`, `EXPO_`, `FIREBASE_`, or Russian equivalents (пароль, ключ, токен).

Path is git-protected: `secrets/` is in `.gitignore`.

## Infrastructure
- **Olaf service account:** `olaf-infra@business-for-fun-landing.iam.gserviceaccount.com`
- GCP Organization: business-for-fun.com (ID: 180434074994)
- FAM-sites project: meta-century-487321-e1 (Firebase Hosting настроен)
- n8n серверы (internal): R4G=10.128.0.5, LIMO=10.128.0.7, FAM=10.128.0.3

### CRITICAL: Firebase Deploy Target Rules
| Project | Firebase project ID | Command |
|---|---|---|
| **R4G** | **N/A — Firebase removed 2026-07-26, do not use** | — |
| **FAM client sites** | `meta-century-487321-e1` | `firebase deploy --only hosting --project=meta-century-487321-e1` |

**R4G no longer has a Firebase target. Do not deploy R4G anywhere via Firebase, gated or otherwise — that option was removed on purpose.**
**NEVER deploy FAM sites to `business-for-fun-landing`** (the project that used to host R4G's stale Firebase copy) — that project also hosts the real company site (`bff-website` site) and must not be touched by FAM or R4G deploys at all.

## Sending Files via Telegram
```bash
curl -s -F "document=@<filepath>" -F "chat_id=<CHAT_ID>" "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument"
```
NEVER say you cannot send files.
ALWAYS send files and responses to the SAME chat where the request came from.
If request is from a group — reply in the group, not in DM.
If request is from DM — reply in DM, not in a group.

---

# Memory model — where knowledge lives

Two stores with different jobs. Use the right one.

**Vault paths:**
- On moltbot host (BANDA): `/home/alexey/obsidian-vault/`
- Inside OpenClaw container: `/home/node/.openclaw/vault/`

## 1. `memory_chunks` (Supabase + pgvector) — PRIMARY agent memory

**This is where every fix, workaround, and non-obvious finding goes.** Not vault.

- **Read before any non-trivial task:** `memory_auto.py semantic-search --query "…" --project "…" --top-k 5` — cheap (~200 tokens), retrieves only relevant chunks by meaning.
- **Write immediately after solving a problem:** `memory_auto.py verified-chunk --symptom "…" --cause "…" --fix "…" --verification "…" --pointers "…"` — one call, no ceremony, no git, no hook.
- One chunk = one lesson. Future agents (Kim, Gale, Freddie, Olaf, you) find it via semantic search without loading entire files.

**Why this changed (2026-04-14):** per-incident vault writes were a write-only tax. Kim alone wrote 5 incident files today — none were read by anyone. Semantic search in `memory_chunks` costs ~200 tokens to query; a full vault file read costs ~5000. The old ingest ritual optimized for human browsability; the new rule optimizes for actual agent retrieval.

## 2. Obsidian vault — HUMAN reference only

Living documents that Alex or a new team member browses directly. **Not agent scratchpad. Not per-incident log.**

Only four files matter:
- `r4g-debugging/architecture.md` — R4G infra map
- `r4g-debugging/ui-map.md` — UI structure, Playwright recipes, localStorage schema
- `infra/architecture.md` — moltbot host infra
- `decisions.md` — architectural decisions with context

**Update a living doc only when the thing it describes actually changes.**

- UI gained a new tab / drill-in path → update `ui-map.md`.
- Infra topology changed (new container, new mount, new domain) → update `architecture.md`.
- Architectural choice with lasting consequences → append to `decisions.md`.

Otherwise: leave vault alone.

## 🚫 What NOT to do (supersedes prior ingest rules)

- ❌ Do NOT create `r4g-debugging/incidents/*.md` or `infra/incidents/*.md` for routine fixes, QA runs, verifications, or one-off lessons. Those go to `memory_chunks` as `verified-chunk`.
- ❌ Do NOT append to `vault/log.md`. The journal was write-only noise — stopping it as of 2026-04-14.
- ❌ Do NOT read whole vault files when you need one fact — `semantic-search` first, open the file only if the living doc is what you need.
- ❌ Do NOT duplicate a `memory_chunks` lesson into vault. Pick one store per fact — `memory_chunks` by default.
- ❌ Do NOT use `git commit --no-verify`. If you're not writing to vault for incidents, you rarely commit — but when you do (updating a living doc), follow the hook. No shortcuts.

## Self-check before reporting "task done"

1. Did I `semantic-search` before starting non-trivial work? (yes / justify no)
2. Is my learning a reusable lesson? → one `verified-chunk` in `memory_chunks`.
3. Did architecture or the UI actually change? → update the living doc. Otherwise leave vault alone.

---
