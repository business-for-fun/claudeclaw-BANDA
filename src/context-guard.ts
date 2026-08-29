/**
 * context-guard.ts — авто-сброс раздутой сессии в ПУТИ ДЕЛЕГАЦИЙ.
 *
 * В bot.ts та же логика (75% warn / 80% auto-reset + после компакции)
 * работает для путей Telegram- и dashboard-сообщений. Путь делегаций
 * исторически не проверялся вообще: агенты, работающие в основном через
 * делегации (gale, kim, olaf), НИКОГДА не сбрасывались — сессии росли
 * неограниченно (инциденты 28–30.07.2026: 223MB у Gale → пустые ответы,
 * падение сессии Kim после e2e-марафона).
 *
 * Модуль самодостаточен (db + handoff + config), чтобы не создавать
 * цикл импортов orchestrator ↔ bot.
 */
import type { UsageInfo } from './agent.js';
import { AGENT_ID, CONTEXT_LIMIT } from './config.js';
import { clearSession, getSessionBaseline, setSessionBaseline } from './db.js';
import { createHandoffSnapshot } from './handoff.js';
import { logger } from './logger.js';

/** Порог автосброса — как в bot.ts (CONTEXT_AUTO_RESET_PCT). Понижен 2026-08-12, см. bot.ts. */
const DELEGATION_AUTO_RESET_PCT = 0.65;

/**
 * Проверить контекст после завершения делегированной задачи и, если он
 * переполнен (или SDK делал компакцию), сбросить сессию с handoff-снапшотом.
 * Между задачами это безопасно: continuity живёт в resume-state.json,
 * карточках, inter_agent_tasks и hive_mind.
 *
 * @returns true, если сессия была сброшена.
 */
export async function maybeAutoResetAfterDelegation(
  chatId: string,
  usage: UsageInfo | null | undefined,
): Promise<boolean> {
  if (!chatId || !usage) return false;

  // 2026-08-29: include cache-read tokens — lastCallInputTokens alone
  // undercounts once a session has meaningful history (most of its context
  // comes back as cached, not fresh input), silently disabling this check.
  const contextTokens = (usage.lastCallInputTokens ?? 0) + (usage.lastCallCacheRead ?? 0);
  let trigger: 'compaction' | 'threshold' | null = null;

  if (usage.didCompact) {
    trigger = 'compaction';
  } else if (contextTokens > 0) {
    let baseline = getSessionBaseline(chatId, AGENT_ID);
    if (baseline === undefined) {
      // Первый замер этой сессии — фиксируем baseline (оверхед системного промпта).
      setSessionBaseline(chatId, contextTokens, AGENT_ID);
      return false;
    }
    const available = CONTEXT_LIMIT - baseline;
    if (available > 0 && (contextTokens - baseline) / available >= DELEGATION_AUTO_RESET_PCT) {
      trigger = 'threshold';
    }
  }

  if (!trigger) return false;

  try {
    await createHandoffSnapshot(chatId, trigger === 'compaction' ? 'compaction' : 'newchat');
  } catch (err) {
    logger.warn(
      { err: err instanceof Error ? err.message : String(err), chatId, agent: AGENT_ID },
      'context-guard: handoff snapshot failed, resetting anyway',
    );
  }

  clearSession(chatId, AGENT_ID);
  logger.info(
    { chatId, agent: AGENT_ID, trigger, contextTokens },
    'context-guard: session auto-reset after delegated task (handoff saved)',
  );
  return true;
}
