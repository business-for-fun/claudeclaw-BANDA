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
if grep -q "const candidates = getMemoriesWithEmbeddings(chatId);" src/db.ts; then
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
sed -i 's/повтор шага/retry step/g' src/orchestrator.ts
sed -i 's/попытка/attempt/g' src/orchestrator.ts
sed -i 's/упала на шаге/failed at step/g' src/orchestrator.ts
sed -i 's/после/after/g' src/orchestrator.ts
sed -i 's/попыток/attempts/g' src/orchestrator.ts

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
