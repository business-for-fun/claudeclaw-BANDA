/**
 * coordinator-notify.ts — событийный «будильник» Начо (2026-08-03).
 *
 * Проблема: Начо — событийная система, его будят только входящие сообщения.
 * Когда агент завершал делегированную задачу, результат ложился в
 * inter_agent_tasks и молча ждал, пока Начо кто-нибудь пнёт (Валера, Alex).
 * Cron-пинок (nacho-followup.sh) был удалён 30.07 после инцидента —
 * поллинг с командным текстом продавливал паузы и плодил дубли.
 *
 * Решение: агент, завершив задачу, САМ отправляет Начо ОДНО информационное
 * сообщение через его dashboard-API (тот же канал, которым Начо получает
 * сообщения людей). Событие, не поллинг; факт, не команда — что делать
 * дальше, Начо решает по своим правилам (Follow-up протокол, паузы,
 * enforcement). Telegram для этого не годится: боты не видят сообщений
 * других ботов.
 */
import { AGENT_ID } from './config.js';
import { readEnvFile } from './env.js';
import { logger } from './logger.js';

/** Dashboard координатора (main). Агентские порт-офсеты НЕ влияют на базовый порт. */
const COORDINATOR_URL =
  process.env.COORDINATOR_DASHBOARD_URL ?? 'http://127.0.0.1:3141';

const CARD_RE = /\b(?:BUG|FEAT|FEATURE|TASK)-\d{8}-\d{3}\b/;

export interface CompletionInfo {
  agentName: string;
  taskId: string;
  status: 'completed' | 'failed';
  /** Первые строки результата или текст ошибки. */
  resultHead: string | null;
  /** Промпт задачи — из него достаём ID карточки для контекста. */
  prompt: string;
}

/**
 * Сообщить координатору (main) о завершении делегированной задачи.
 * Fire-and-forget: две попытки, при неудаче — warn в лог и выход.
 * Начо в этот момент может рестартовать/быть занят — тогда результат
 * подберётся по резервному правилу («проснулся → проверь completed»).
 */
export async function notifyCoordinator(info: CompletionInfo): Promise<void> {
  // Main о своих задачах не уведомляет сам себя.
  if (AGENT_ID === 'main') return;

  const token = readEnvFile(['DASHBOARD_TOKEN']).DASHBOARD_TOKEN;
  if (!token) {
    logger.warn('coordinator-notify: DASHBOARD_TOKEN не найден в .env — уведомление пропущено');
    return;
  }

  const card = info.prompt.match(CARD_RE)?.[0];
  const head = (info.resultHead ?? '').replace(/\s+/g, ' ').slice(0, 300);
  const message =
    info.status === 'completed'
      ? `✅ [${info.agentName}] завершил задачу ${info.taskId.slice(0, 8)}${card ? ` (${card})` : ''}.\n` +
        `Результат (начало): ${head || '<пусто>'}\n` +
        `Полный текст: inter_agent_tasks, id=${info.taskId}. ` +
        `Действуй по Follow-up протоколу: отчёт в чат постановки задачи, затем следующий шаг конвейера (с учётом пауз и правил approve).`
      : `❌ [${info.agentName}] задача ${info.taskId.slice(0, 8)}${card ? ` (${card})` : ''} завершилась ОШИБКОЙ: ${head || '<без текста>'}\n` +
        `Действуй по Empty-response/error протоколу — не ретраить автоматически без проверки side effects.`;

  const url = `${COORDINATOR_URL}/api/chat/send?token=${encodeURIComponent(token)}`;
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message }),
        signal: AbortSignal.timeout(10_000),
      });
      if (res.ok) {
        logger.info({ taskId: info.taskId, status: info.status }, 'coordinator-notify: Начо уведомлён');
        return;
      }
      logger.warn({ taskId: info.taskId, http: res.status, attempt }, 'coordinator-notify: dashboard ответил не-2xx');
    } catch (err) {
      logger.warn(
        { taskId: info.taskId, attempt, err: err instanceof Error ? err.message : String(err) },
        'coordinator-notify: не удалось доставить уведомление',
      );
    }
    if (attempt === 1) await new Promise((r) => setTimeout(r, 5_000));
  }
}
