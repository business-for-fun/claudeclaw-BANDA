import { logger } from './logger.js';

/**
 * TASK-20260828-001: default ceiling on how long a single handler() may run
 * before the queue gives up waiting on it and moves on. Two confirmed
 * incidents (2026-08-25 Valera DM ~40min, 2026-08-27/28 R4G_Debug ~9h) showed
 * a handler can hang forever on a stuck network call (ETIMEDOUT-class
 * failures against api.telegram.org that never actually reject) without
 * ever throwing — so the chain for that chatId sat blocked until someone
 * manually restarted banda-main.service.
 *
 * MUST stay comfortably above `AGENT_TIMEOUT_MS` (config.ts, defaults to
 * 600_000ms = 10 minutes — the sanctioned budget for a normal, legitimate
 * agent turn). A handler wraps a full agent run PLUS whatever happens before
 * it (media download) and after it (sending the reply), so this queue-level
 * timeout is the outer envelope around all of that, not a replacement for
 * AGENT_TIMEOUT_MS's own abort logic. If this were set close to or below
 * AGENT_TIMEOUT_MS, a normal 8-9 minute agent turn that is actively
 * succeeding would be misdiagnosed as "hung" and abandoned mid-flight —
 * exactly the false positive this mechanism must not create. 15 minutes
 * gives ~5 minutes of margin beyond AGENT_TIMEOUT_MS for the agent's own
 * abort to actually unwind plus reply delivery, while still being a last
 * resort net, not a performance budget: per-network-call timeouts (see
 * media.ts's httpsGet/httpsDownload) are the first line of defense and
 * should turn a stuck call into a real rejection long before 15 minutes.
 */
export const DEFAULT_HANDLER_TIMEOUT_MS = 15 * 60 * 1000;

/** Info handed to an onTimeout callback when a handler is abandoned. */
export interface QueueTimeoutInfo {
  chatId: string;
  hungForMs: number;
}

/**
 * Per-chat FIFO message queue. Ensures only one message is processed
 * at a time per chat_id, preventing race conditions on sessions,
 * abort controllers, and conversation logs.
 *
 * Exported (not just the `messageQueue` singleton below) so tests can
 * construct isolated instances instead of sharing module-level state.
 */
export class MessageQueue {
  private chains = new Map<string, Promise<void>>();
  private pending = new Map<string, number>();

  /**
   * Enqueue a message handler for a given chat. Handlers for the same
   * chatId run sequentially in FIFO order. Different chatIds run in parallel.
   *
   * If `handler()` has not settled after `timeoutMs` (default
   * `DEFAULT_HANDLER_TIMEOUT_MS`), the queue chain for this chatId is
   * released immediately — the NEXT queued message for this chat proceeds
   * right away, instead of waiting behind a handler that may never finish.
   * The abandoned handler keeps running in the background (JS promises
   * cannot be cancelled); its eventual result is discarded and any late
   * rejection is caught so it never surfaces as an unhandled rejection.
   *
   * `onTimeout`, if given, is called once the chain has already been
   * released — it is expected to notify the user via a path that does NOT
   * depend on whatever made the original handler hang (e.g. a dedicated
   * short-timeout API client), so a broken network path can't also break
   * the fallback notification. Errors thrown by `onTimeout` are logged and
   * swallowed — they must never re-block the (already-released) chain.
   */
  enqueue(
    chatId: string,
    handler: () => Promise<void>,
    onTimeout?: (info: QueueTimeoutInfo) => Promise<void> | void,
    timeoutMs: number = DEFAULT_HANDLER_TIMEOUT_MS,
  ): void {
    const queued = (this.pending.get(chatId) ?? 0) + 1;
    this.pending.set(chatId, queued);

    if (queued > 1) {
      logger.info({ chatId, queued }, 'Message queued (another is processing)');
    }

    const prev = this.chains.get(chatId) ?? Promise.resolve();
    const next = prev.then(async () => {
      const startedAt = Date.now();
      let released = false;

      const releaseChain = () => {
        if (released) return;
        released = true;
        const remaining = (this.pending.get(chatId) ?? 1) - 1;
        if (remaining <= 0) {
          this.pending.delete(chatId);
          this.chains.delete(chatId);
        } else {
          this.pending.set(chatId, remaining);
        }
      };

      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        // Invoke handler() exactly once. Racing it against a timeout — rather
        // than e.g. wrapping it in AbortSignal — works with any handler,
        // including ones with no cancellation support at all.
        const handlerPromise = handler();
        const timedOut = await Promise.race([
          handlerPromise.then(() => false as const),
          new Promise<true>((resolve) => {
            timer = setTimeout(() => resolve(true), timeoutMs);
          }),
        ]);

        if (timedOut) {
          const hungForMs = Date.now() - startedAt;
          logger.error(
            { chatId, hungForMs, timeoutMs },
            'Message handler exceeded timeout — releasing queue chain for this chat',
          );
          // Release BEFORE awaiting onTimeout: a slow/failing fallback must
          // not re-introduce the exact hang this mechanism exists to avoid.
          releaseChain();

          // The real handler is still running somewhere; make sure it can
          // never crash the process later via an unhandled rejection. Its
          // outcome is otherwise ignored — a new chain may already be
          // active for this chatId by the time it settles.
          handlerPromise.catch((err) => {
            logger.warn(
              { err, chatId },
              'Handler abandoned by timeout eventually rejected (already released, ignoring)',
            );
          });

          if (onTimeout) {
            // Fire-and-forget, deliberately NOT awaited: the already-enqueued
            // NEXT handler for this chatId is chained via `.then()` onto this
            // very async function's completion, so awaiting a slow (or
            // hanging) onTimeout here would recreate the exact problem this
            // mechanism exists to fix.
            Promise.resolve()
              .then(() => onTimeout({ chatId, hungForMs }))
              .catch((fallbackErr) => {
                logger.error({ err: fallbackErr, chatId }, 'Timeout fallback notification failed');
              });
          }
        }
      } catch (err) {
        logger.error({ err, chatId }, 'Unhandled message error');
      } finally {
        if (timer) clearTimeout(timer);
        // No-op if the timeout path already released this chain.
        releaseChain();
      }
    });

    this.chains.set(chatId, next);
  }

  /** Number of chats with pending messages. */
  get activeChats(): number {
    return this.chains.size;
  }

  /** Number of pending messages for a given chat. */
  queuedFor(chatId: string): number {
    return this.pending.get(chatId) ?? 0;
  }
}

export const messageQueue = new MessageQueue();
