#!/bin/bash
# Apply local customizations after git pull
cd /home/alexey/banda

# Translate Russian templates to English
sed -i "s/Agent: 'Запускаю подзадачу'/Agent: 'Running subtask'/" src/agent.ts
sed -i "s/Запускаю подзадачу: /Running subtask: /g" src/agent.ts
sed -i "s/Запускаю подзадачу/Running subtask/g" src/agent.ts
sed -i "s/Подзадача завершена: /Subtask completed: /g" src/agent.ts
sed -i "s/Подзадача завершена/Subtask completed/g" src/agent.ts
sed -i "s/Отчёт от/Report from/g" src/orchestrator.ts
sed -i "s/Параллельная делегация завершена:/Parallel delegation completed:/g" src/orchestrator.ts
sed -i "s/успешно/succeeded/g" src/orchestrator.ts
sed -i "s/ошибок/errors/g" src/orchestrator.ts
sed -i 's/Цепочка "/Chain "/g' src/orchestrator.ts
sed -i "s/\" выполнена./\" completed./g" src/orchestrator.ts
sed -i "s/Результат:/Result:/g" src/orchestrator.ts

# Fix timezone
sed -i "s/timeZone: 'YOUR_TIMEZONE'/timeZone: 'Europe\/Warsaw'/" src/task-board.ts

# Fix isAuthorised for group support
# (only if original single-ID check exists)
if grep -q "return chatId.toString() === ALLOWED_CHAT_ID;" src/bot.ts; then
  sed -i 's/return chatId.toString() === ALLOWED_CHAT_ID;/const allowed = ALLOWED_CHAT_ID.split(",").map(id => id.trim()); return allowed.includes(chatId.toString());/' src/bot.ts
fi

echo "Patches applied"

# Patch: cross-chat memory search - include all chats, not just current
# 2026-08-29: guard on the ABSENCE of the patch marker, not the presence of
# the anchor line — the anchor survives patching, so the old guard re-inserted
# the block on every run (found doubled = a const-redeclaration compile error).
if ! grep -q "allChatCandidates" src/db.ts && grep -q "const candidates = getMemoriesWithEmbeddings(chatId);" src/db.ts; then
  sed -i 's/const candidates = getMemoriesWithEmbeddings(chatId);/const candidates = getMemoriesWithEmbeddings(chatId);\n    \/\/ Also include memories from all chats for cross-context awareness\n    const allChatCandidates = getMemoriesWithEmbeddings(null as any);\n    for (const m of allChatCandidates) { if (!candidates.find(c => c.id === m.id)) candidates.push(m); }/' src/db.ts
fi

# Patch: global memory search (cross-chat context)
# Remove chat_id filter from embedding search so all memories are searchable from any chat
sed -i "s/SELECT id, embedding, summary, importance, created_at, agent_id, memory_type FROM memories WHERE chat_id = ? AND embedding IS NOT NULL ORDER BY created_at DESC LIMIT ?/SELECT id, embedding, summary, importance, created_at, agent_id, memory_type FROM memories WHERE embedding IS NOT NULL ORDER BY created_at DESC LIMIT ?/" src/db.ts
sed -i "s/.all(chatId, MAX_EMBEDDING_CANDIDATES)/.all(MAX_EMBEDDING_CANDIDATES)/" src/db.ts

# Patch: prepend sender name in group chats
if grep -q "messageQueue.enqueue(chatIdStr, () => handleMessage(ctx, text));" src/bot.ts; then
  python3 -c "
content = open('src/bot.ts').read()
old = '    messageQueue.enqueue(chatIdStr, () => handleMessage(ctx, text));'
new = '''    // Prepend sender name in group chats so agent knows who is talking
    const isGroup = ctx.chat!.type === 'group' || ctx.chat!.type === 'supergroup';
    const senderName = ctx.from?.first_name || ctx.from?.username || 'Unknown';
    const senderUsername = ctx.from?.username ? '@' + ctx.from.username : '';
    const enrichedText = isGroup
      ? '[From: ' + senderName + ' ' + senderUsername + '] ' + text
      : text;
    messageQueue.enqueue(chatIdStr, () => handleMessage(ctx, enrichedText));'''
content = content.replace(old, new)
open('src/bot.ts', 'w').write(content)
"
fi

# Patch: only respond in groups when @mentioned or replied to
python3 -c "
content = open('src/bot.ts').read()
if 'only respond if bot is @mentioned' not in content and 'const isGroup = ctx.chat!.type' in content:
    old = '    const isGroup = ctx.chat!.type === \'group\' || ctx.chat!.type === \'supergroup\';\n    const senderName'
    new = '''    const isGroup = ctx.chat!.type === 'group' || ctx.chat!.type === 'supergroup';

    // In groups: only respond if bot is @mentioned or message is a reply to bot
    if (isGroup) {
      const botUsername = ctx.me?.username || '';
      const isMentioned = botUsername && text.includes(\"@\" + botUsername);
      const isReplyToBot = ctx.message?.reply_to_message?.from?.id === ctx.me?.id;
      if (!isMentioned && !isReplyToBot) {
        return;
      }
    }

    const senderName'''
    content = content.replace(old, new)
    open('src/bot.ts', 'w').write(content)
" 2>/dev/null || true
sed -i "s/Bash: 'Выполняю команду'/Bash: 'Running command'/" src/agent.ts
sed -i "s/Принял задачу от/Task received from/g" src/orchestrator.ts
sed -i 's/TIMEOUT_MS="${3:-600000}"/TIMEOUT_MS="${3:-2400000}"/' scripts/delegate-to-agent.sh
sed -i 's/TIMEOUT_MS="${3:-1800000}"/TIMEOUT_MS="${3:-2400000}"/' scripts/delegate-to-agent.sh
sed -i "s/const DEFAULT_TIMEOUT_MS = 10 \* 60 \* 1000;/const DEFAULT_TIMEOUT_MS = 40 * 60 * 1000;/" src/orchestrator.ts
sed -i "s/const DEFAULT_TIMEOUT_MS = 30 \* 60 \* 1000;/const DEFAULT_TIMEOUT_MS = 40 * 60 * 1000;/" src/orchestrator.ts
sed -i "s/tuco|lalo|gale|kim)/tuco|lalo|gale|kim|olaf|rob|freddie)/" scripts/delegate-to-agent.sh
sed -i "s/Задача выполнена! Отправляю результат →/Task completed! Sending result →/g" src/orchestrator.ts

# Patch: remaining Russian agent tool labels
sed -i "s/Подзадача не удалась:/Subtask failed:/g" src/agent.ts
sed -i "s/Читаю файл/Reading file/g" src/agent.ts
sed -i "s/Пишу файл/Writing file/g" src/agent.ts
sed -i "s/Редактирую файл/Editing file/g" src/agent.ts
sed -i "s/Ищу в коде/Searching code/g" src/agent.ts
sed -i "s/Ищу файлы/Finding files/g" src/agent.ts
sed -i "s/Ищу в интернете/Searching web/g" src/agent.ts
sed -i "s/Загружаю страницу/Fetching page/g" src/agent.ts
sed -i "s/Редактирую ноутбук/Editing notebook/g" src/agent.ts
sed -i "s/Готовлю вопрос/Preparing question/g" src/agent.ts
sed -i "s/Использую скилл/Using skill/g" src/agent.ts

# Patch: chain retry messages in orchestrator
# 2026-08-29: replaced blanket word-level seds ('после'→'after', 'попытка'→
# 'attempt', 'попыток'→'attempts') with phrase-anchored ones — the blanket
# versions mangled unrelated Russian UI strings added later (e.g. the
# auto-reset notification became "сброшена автоматически after задачи").
sed -i 's/повтор шага/retry step/g' src/orchestrator.ts
sed -i 's/упала на шаге/failed at step/g' src/orchestrator.ts
sed -i 's/, попытка ${attempt/, attempt ${attempt/g' src/orchestrator.ts
sed -i 's/) после ${/) after ${/g' src/orchestrator.ts
sed -i 's/ попыток`/ attempts`/g' src/orchestrator.ts

# Patch: disable in-process fallback for other agents
python3 -c "
content = open('src/orchestrator.ts').read()
old = '''    } catch (err) {
      logger.warn({ agentId, err: err instanceof Error ? err.message : String(err) },
        'Remote delegation failed, falling back to in-process');
    }
  }

  // ── Fallback: in-process execution ──'''
if old in content:
    new = '''    } catch (err) {
      logger.error({ agentId, err: err instanceof Error ? err.message : String(err) },
        'Remote delegation failed — NO FALLBACK');
      completeInterAgentTask(taskId, 'failed', 'Remote delegation failed: ' + (err instanceof Error ? err.message : String(err)));
      return { agentId, taskId, text: 'ERROR: Could not reach agent ' + agentId + '. No fallback.', durationMs: Date.now() - start, usage: { inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 0, totalCostUsd: 0, didCompact: false, preCompactTokens: null, lastCallCacheRead: 0, lastCallInputTokens: 0 } };
    }
  } else if (AGENT_ID !== agentId) {
    completeInterAgentTask(taskId, 'failed', 'Agent has no dashboard port');
    return { agentId, taskId, text: 'ERROR: Agent ' + agentId + ' has no dashboard port.', durationMs: Date.now() - start, usage: { inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 0, totalCostUsd: 0, didCompact: false, preCompactTokens: null, lastCallCacheRead: 0, lastCallInputTokens: 0 } };
  }

  // ── Fallback: in-process execution (ONLY for self-delegation) ──'''
    content = content.replace(old, new)
    open('src/orchestrator.ts', 'w').write(content)
    print('No-fallback patch applied')
" 2>/dev/null || true

# R4G_Debug observer: log group messages for context (survives updates)
python3 scripts/patches/r4g-debug-observer.py 2>/dev/null || true

# Patch: bounded timeout on sendTyping — this call runs before the agent's
# own soft/hard-deadline safety net, so an unbounded hang here can wedge a
# chat's message queue for hours with no auto-recovery. Root cause of the
# 2026-08-19/20 19h-stuck DM incident (Nacho). See memory:
# project_banda_sendtyping_hang_20260820.
if grep -q "await api.sendChatAction(chatId, 'typing');" src/bot.ts; then
  sed -i "s/await api.sendChatAction(chatId, 'typing');/await api.sendChatAction(chatId, 'typing', undefined, AbortSignal.timeout(5000) as any);/" src/bot.ts
fi

# Patch: dashboard /api/delegate default timeout 10min -> 90min (2026-08-30).
# The 10-min clamp on the RECEIVING side killed any jest-length delegated task
# at exactly 10:00 ("Agent query aborted") regardless of the caller's 90-min
# defaults — root cause of Freddie/Olaf never reaching git commit 29.08.
# Plain substitution — old string disappears, so this is naturally idempotent.
sed -i 's/const timeoutMs = body.timeoutMs || 10 \* 60 \* 1000;/const timeoutMs = body.timeoutMs || 90 * 60 * 1000;/' src/dashboard.ts

# Patch: session auto-reset — two compounding bugs (2026-08-29), see commit
# f218ee76. Without these the auto-reset safety net can never fire and every
# oversized session ends in a silent hang needing manual /newchat.
# (a) setSession INSERT OR REPLACE wiped baseline_tokens on every save.
if grep -q "INSERT OR REPLACE INTO sessions" src/db.ts; then
  python3 -c "
content = open('src/db.ts').read()
old = \"'INSERT OR REPLACE INTO sessions (chat_id, agent_id, session_id, updated_at) VALUES (?, ?, ?, ?)',\"
new = '''\`INSERT INTO sessions (chat_id, agent_id, session_id, updated_at) VALUES (?, ?, ?, ?)
     ON CONFLICT(chat_id, agent_id) DO UPDATE SET session_id = excluded.session_id, updated_at = excluded.updated_at\`,'''
content = content.replace(old, new)
open('src/db.ts', 'w').write(content)
"
fi
# (b) context size must include cache-read tokens, not just fresh input.
sed -i "s/const contextTokens = usage.lastCallInputTokens;/const contextTokens = usage.lastCallInputTokens + usage.lastCallCacheRead;/g" src/bot.ts
sed -i "s/const contextTokens = usage.lastCallInputTokens ?? 0;/const contextTokens = (usage.lastCallInputTokens ?? 0) + (usage.lastCallCacheRead ?? 0);/" src/context-guard.ts

# Patch: exclude 'user' from settingSources (2026-09-01). The services run as
# amileev, so the 'user' scope injected the operator's personal
# ~/.claude/CLAUDE.md (host ops map, secrets paths) into EVERY agent session
# (~1.8K tokens of role-foreign context). Fleet-needed user-scope plugins
# (last30days for lalo) are enabled in .claude/settings.json (project scope,
# a banda-local file untouched by vendor pulls). Old string disappears — idempotent.
sed -i "s/settingSources: \['project', 'user'\],/settingSources: ['project'],/" src/agent.ts

# Patch: do not pass systemPrompt for sub-agents (2026-09-01). Their CLAUDE.md
# loads via settingSources:['project'] from cwd anyway — passing it duplicated
# the file (~5-7K tokens/session) and replaced the SDK default system prompt.
# Guard: absence of the patch marker comment; anchor line survives, marker doesn't.
python3 -c "
content = open('src/index.ts').read()
if 'systemPrompt deliberately NOT passed for sub-agents' not in content:
    old = '''    obsidian: agentConfig.obsidian,
    systemPrompt,
  });'''
    new = '''    obsidian: agentConfig.obsidian,
    // systemPrompt deliberately NOT passed for sub-agents (2026-09-01): the
    // agent's own CLAUDE.md already loads via settingSources:['project'] from
    // its cwd — see vault gotcha 01.09.
  });'''
    content = content.replace(old, new)
    open('src/index.ts', 'w').write(content)
" 2>/dev/null || true

# Patch: FIFO queue for in-process (self-)delegations (2026-09-03).
# Two concurrent delegations in one agent process stack memory profiles
# (full jest + a second claude subprocess) and OOM the cgroup (gale 02.09
# 19:31, kim 02.09 16:25). Guard: absence of the patch marker function name.
python3 - << 'PYEOF'
content = open('src/orchestrator.ts').read()
if 'runQueuedSelfDelegation' not in content:
    old_import = """import { notifyCoordinator } from './coordinator-notify.js';
"""
    new_import = old_import + """
// Self-delegation FIFO queue (2026-09-03): one in-process task at a time.
let selfDelegationChain: Promise<void> = Promise.resolve();
function runQueuedSelfDelegation<T>(fn: () => Promise<T>): Promise<T> {
  const p = selfDelegationChain.then(fn);
  selfDelegationChain = p.then(() => undefined, () => undefined);
  return p;
}
"""
    old_run = """    // Create an AbortController with timeout
    const abortCtrl = new AbortController();
    const timer = setTimeout(() => abortCtrl.abort(), timeoutMs);

    // Use persistent session when agent runs in its own process (AGENT_ID === agentId)
    // This lets the agent remember delegated tasks when user talks to it via Telegram
    const isSelfProcess = AGENT_ID === agentId;
    const existingSessionId = isSelfProcess && chatId ? getSession(chatId, agentId) : undefined;

    try {
      const result = await runAgent(
        fullPrompt,
        existingSessionId, // resume session if agent's own process, fresh otherwise
        () => {}, // no typing indicator needed for sub-delegation
        undefined, // no progress callback for inner agent
        agentConfig.model, // use agent's model from agent.yaml (e.g. haiku for Tuco)
        abortCtrl,
      );"""
    new_run = """    // Use persistent session when agent runs in its own process (AGENT_ID === agentId)
    const isSelfProcess = AGENT_ID === agentId;
    let timer: ReturnType<typeof setTimeout> | undefined;

    try {
      const result = await runQueuedSelfDelegation(async () => {
        const abortCtrl = new AbortController();
        timer = setTimeout(() => abortCtrl.abort(), timeoutMs);
        const existingSessionId = isSelfProcess && chatId ? getSession(chatId, agentId) : undefined;
        return runAgent(
          fullPrompt,
          existingSessionId,
          () => {},
          undefined,
          agentConfig.model,
          abortCtrl,
        );
      });"""
    if old_import in content and old_run in content:
        content = content.replace(old_import, new_import).replace(old_run, new_run)
        open('src/orchestrator.ts', 'w').write(content)
        print('Self-delegation queue patch applied')
    else:
        print('WARNING: self-delegation queue anchors not found — vendor code changed, patch skipped')
PYEOF

# Patch: inject Telegram reply/quote context into the agent prompt (2026-09-03).
# "Quote and Reply" carries replied-to text + quote as metadata; without this
# the agent gets a bare follow-up ("опиши, что это") with no referent.
# Guard: absence of the patch marker variable name.
python3 - << 'PYEOF'
content = open('src/bot.ts').read()
if 'replyContext' not in content:
    old = """    const senderName = ctx.from?.first_name || ctx.from?.username || 'Unknown';
    const senderUsername = ctx.from?.username ? `@${ctx.from.username}` : '';
    let enrichedText = isGroup
      ? `[From: ${senderName} ${senderUsername}] ${text}`
      : text;"""
    new = """    const senderName = ctx.from?.first_name || ctx.from?.username || 'Unknown';
    const senderUsername = ctx.from?.username ? `@${ctx.from.username}` : '';
    // Reply/quote context (2026-09-03): see vault gotcha.
    let replyContext = '';
    {
      const rep = ctx.message?.reply_to_message;
      const quoted = (ctx.message as { quote?: { text?: string } })?.quote?.text
        || rep?.text || rep?.caption;
      if (quoted) {
        const repFrom = rep?.from?.id === ctx.me?.id
          ? 'your earlier message'
          : (rep?.from?.first_name || rep?.from?.username || 'another message');
        const clipped = quoted.length > 1500 ? `${quoted.slice(0, 1500)}…` : quoted;
        replyContext = `[In reply to ${repFrom}: «${clipped}»]\\n`;
      }
    }
    let enrichedText = isGroup
      ? `${replyContext}[From: ${senderName} ${senderUsername}] ${text}`
      : `${replyContext}${text}`;"""
    if old in content:
        content = content.replace(old, new)
        open('src/bot.ts', 'w').write(content)
        print('Reply-context patch applied')
    else:
        print('WARNING: reply-context anchor not found — vendor code changed, patch skipped')
PYEOF

# Patch: self-heal dead session pointers (2026-09-04). Claude Code rotates
# transcripts (~30 days) while the sessions table still references them —
# resume then fails "No conversation found with session ID" (34 dead rows
# swept fleet-wide 04.09). Retry once fresh; caller saves newSessionId which
# overwrites the dead row. Guard: absence of the marker 'sessionRecovered'.
python3 - << 'PYEOF'
content = open('src/agent.ts').read()
if 'sessionRecovered' not in content:
    old_iface = """  aborted?: boolean;
}"""
    new_iface = """  aborted?: boolean;
  sessionRecovered?: boolean;
}"""
    old_catch = """    if (abortController?.signal.aborted) {
      logger.info('Agent query aborted by user');
      return { text: null, newSessionId, usage, aborted: true };
    }
    throw err;"""
    new_catch = """    if (abortController?.signal.aborted) {
      logger.info('Agent query aborted by user');
      return { text: null, newSessionId, usage, aborted: true };
    }
    const errMsg = err instanceof Error ? err.message : String(err);
    if (sessionId && /No conversation found with session ID/i.test(errMsg)) {
      logger.warn({ sessionId }, 'Dead session pointer (transcript rotated away) — retrying with a fresh session');
      const fresh = await runAgent(message, undefined, onTyping, onProgress, model, abortController);
      return { ...fresh, sessionRecovered: true };
    }
    throw err;"""
    if old_iface in content and old_catch in content:
        content = content.replace(old_iface, new_iface, 1).replace(old_catch, new_catch, 1)
        open('src/agent.ts', 'w').write(content)
        print('Dead-session self-heal patch applied (agent.ts)')
    else:
        print('WARNING: dead-session anchors not found in agent.ts — vendor changed, patch skipped')

bot = open('src/bot.ts').read()
if 'sessionRecovered' not in bot:
    old_save = """      setSession(chatIdStr, result.newSessionId, AGENT_ID);
      logger.info({ newSessionId: result.newSessionId }, 'Session saved');"""
    new_save = """      setSession(chatIdStr, result.newSessionId, AGENT_ID);
      logger.info({ newSessionId: result.newSessionId }, 'Session saved');
      if (result.sessionRecovered) {
        void ctx.reply('🔄 Прошлая сессия этого чата была утеряна (ротация истории) — начал свежую автоматически. Память, карточки и resume-state не затронуты.').catch(() => {});
      }"""
    if old_save in bot:
        open('src/bot.ts', 'w').write(bot.replace(old_save, new_save, 1))
        print('Dead-session notice patch applied (bot.ts)')
    else:
        print('WARNING: dead-session notice anchor not found in bot.ts — patch skipped')
PYEOF

# Patch: 30-min floor for explicit delegation timeouts (2026-09-04).
# 600000 = 10 minutes, not 60 — Nacho kept passing it as arg 3; every heavy
# delegation aborted at exactly 10:00 with an empty result, triggering bogus
# /newchat requests. Guard: absence of the MIN_TIMEOUT_MS marker.
python3 - << 'PYEOF'
s = open('scripts/delegate-to-agent.sh').read()
if 'MIN_TIMEOUT_MS' not in s and 'TIMEOUT_MS="${3:-5400000}"' in s:
    guard = '''TIMEOUT_MS="${3:-5400000}"
MIN_TIMEOUT_MS=5400000
if [ "$TIMEOUT_MS" -lt "$MIN_TIMEOUT_MS" ]; then
  echo "WARN: timeoutMs=$TIMEOUT_MS занижен и поднят до штатных 90 минут. НЕ передавай третий аргумент — дефолт правильный." >&2
  TIMEOUT_MS=$MIN_TIMEOUT_MS
fi'''
    s = s.replace('TIMEOUT_MS="${3:-5400000}"', guard)
    open('scripts/delegate-to-agent.sh','w').write(s)
    print('Timeout floor patch applied')
PYEOF

# Patch: background-wait nudge (2026-09-29). An agent that starts its final test
# run with run_in_background ends the turn "waiting for a notification" that
# never arrives in a headless delegation; the coordinator then asks for a
# useless /newchat (Freddie burned ~4h of queue, Kim looped the same day).
# One automatic in-session nudge finishes the job. Guard: marker function name.
python3 - << 'PYEOF_BGN'
s = open('src/orchestrator.ts').read()
if 'endsWaitingForBackground' not in s:
    anchor = "// \u2500\u2500 Self-delegation FIFO queue (2026-09-03)"
    old_call = "      const result = await runQueuedSelfDelegation(async () => {"
    tail = """      clearTimeout(timer);
      clearInterval(progressTimer);

      // Save session so Telegram messages can resume it"""
    i = s.find(anchor)
    if i >= 0 and old_call in s and tail in s:
        helper = open('scripts/patches/bg-nudge-helper.ts.txt').read()
        nudge = open('scripts/patches/bg-nudge-block.ts.txt').read()
        s = s[:i] + helper + s[i:]
        s = s.replace(old_call, "      let result = await runQueuedSelfDelegation(async () => {", 1)
        s = s.replace(tail, """      clearTimeout(timer);
      clearInterval(progressTimer);

""" + nudge + "      // Save session so Telegram messages can resume it", 1)
        open('src/orchestrator.ts', 'w').write(s)
        print('Background-wait nudge patch applied')
    else:
        print('WARNING: background-wait anchors not found - vendor changed, patch skipped')
PYEOF_BGN
