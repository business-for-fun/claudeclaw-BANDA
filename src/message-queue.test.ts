import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

vi.mock('./logger.js', () => ({
  logger: { warn: vi.fn(), error: vi.fn(), info: vi.fn(), debug: vi.fn() },
}));

import { logger } from './logger.js';
import { MessageQueue, DEFAULT_HANDLER_TIMEOUT_MS } from './message-queue.js';

// MessageQueue is not exported from the source module by default (only the
// singleton `messageQueue` is) for production use, but tests need a fresh
// instance per test to avoid cross-test chain leakage — see message-queue.ts
// for the `export class MessageQueue` used here.

describe('MessageQueue', () => {
  let queue: MessageQueue;

  beforeEach(() => {
    vi.clearAllMocks();
    vi.useFakeTimers();
    queue = new MessageQueue();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('runs a single handler to completion and cleans up its chain', async () => {
    let ran = false;
    queue.enqueue('chat1', async () => {
      ran = true;
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(ran).toBe(true);
    expect(queue.activeChats).toBe(0);
    expect(queue.queuedFor('chat1')).toBe(0);
  });

  it('runs handlers for the same chatId strictly in FIFO order', async () => {
    const order: number[] = [];
    queue.enqueue('chat1', async () => {
      order.push(1);
    });
    queue.enqueue('chat1', async () => {
      order.push(2);
    });
    queue.enqueue('chat1', async () => {
      order.push(3);
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(order).toEqual([1, 2, 3]);
  });

  it('runs handlers for different chatIds independently (no cross-chat blocking)', async () => {
    let chat2Ran = false;
    // chat1's handler hangs forever; chat2 must not wait on it.
    queue.enqueue('chat1', () => new Promise<void>(() => {}));
    queue.enqueue('chat2', async () => {
      chat2Ran = true;
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(chat2Ran).toBe(true);
  });

  // ── TASK-20260828-001: the actual fix ────────────────────────────────

  it('does not block subsequent messages for the same chat when a handler hangs past the timeout', async () => {
    const order: string[] = [];

    // Simulates the real incident: a handler stuck on a network call that
    // never rejects and never resolves.
    queue.enqueue('chat1', () => {
      order.push('first-started');
      return new Promise<void>(() => {
        /* never settles */
      });
    });

    let secondRan = false;
    queue.enqueue('chat1', async () => {
      order.push('second-started');
      secondRan = true;
    });

    // Before the timeout elapses, the second message must still be waiting.
    await vi.advanceTimersByTimeAsync(DEFAULT_HANDLER_TIMEOUT_MS - 1);
    expect(secondRan).toBe(false);

    // Once the timeout elapses, the chain must release and the second
    // message must run.
    await vi.advanceTimersByTimeAsync(2);
    expect(secondRan).toBe(true);
    expect(order).toEqual(['first-started', 'second-started']);
  });

  it('calls onTimeout with chatId and an accurate hungForMs after abandoning a hung handler', async () => {
    queue.enqueue(
      'chat42',
      () => new Promise<void>(() => {}),
      async (info) => {
        expect(info.chatId).toBe('chat42');
        expect(info.hungForMs).toBeGreaterThanOrEqual(DEFAULT_HANDLER_TIMEOUT_MS);
      },
    );
    await vi.advanceTimersByTimeAsync(DEFAULT_HANDLER_TIMEOUT_MS + 1);
  });

  it('does NOT call onTimeout when the handler completes within the timeout', async () => {
    const onTimeout = vi.fn();
    queue.enqueue(
      'chat1',
      async () => {
        /* completes immediately */
      },
      onTimeout,
    );
    await vi.advanceTimersByTimeAsync(DEFAULT_HANDLER_TIMEOUT_MS + 1);
    expect(onTimeout).not.toHaveBeenCalled();
  });

  it('respects a custom timeoutMs instead of the default', async () => {
    let secondRan = false;
    queue.enqueue('chat1', () => new Promise<void>(() => {}), undefined, 1000);
    queue.enqueue('chat1', async () => {
      secondRan = true;
    });

    await vi.advanceTimersByTimeAsync(999);
    expect(secondRan).toBe(false);
    await vi.advanceTimersByTimeAsync(2);
    expect(secondRan).toBe(true);
  });

  it('releases the chain immediately even if onTimeout itself is slow, then still calls it', async () => {
    let secondRan = false;
    let onTimeoutResolved = false;
    queue.enqueue(
      'chat1',
      () => new Promise<void>(() => {}),
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 10_000));
        onTimeoutResolved = true;
      },
    );
    queue.enqueue('chat1', async () => {
      secondRan = true;
    });

    await vi.advanceTimersByTimeAsync(DEFAULT_HANDLER_TIMEOUT_MS + 1);
    // Second message must not wait for onTimeout's own 10s delay.
    expect(secondRan).toBe(true);
    expect(onTimeoutResolved).toBe(false);

    await vi.advanceTimersByTimeAsync(10_000);
    expect(onTimeoutResolved).toBe(true);
  });

  it('logs and swallows an onTimeout error instead of throwing', async () => {
    queue.enqueue(
      'chat1',
      () => new Promise<void>(() => {}),
      async () => {
        throw new Error('fallback notification failed');
      },
    );
    await expect(vi.advanceTimersByTimeAsync(DEFAULT_HANDLER_TIMEOUT_MS + 1)).resolves.not.toThrow();
    expect(logger.error).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 'chat1' }),
      'Timeout fallback notification failed',
    );
  });

  it('does not crash when an abandoned (timed-out) handler eventually rejects', async () => {
    let rejectHandler: (err: Error) => void = () => {};
    queue.enqueue('chat1', () => new Promise<void>((_resolve, reject) => {
      rejectHandler = reject;
    }));
    queue.enqueue('chat1', async () => {});

    await vi.advanceTimersByTimeAsync(DEFAULT_HANDLER_TIMEOUT_MS + 1);
    // The handler is now abandoned (chain already released). Rejecting it
    // late must not surface as an unhandled rejection / throw.
    expect(() => rejectHandler(new Error('ETIMEDOUT, eventually'))).not.toThrow();
    await vi.advanceTimersByTimeAsync(0);
    expect(logger.warn).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 'chat1' }),
      expect.stringContaining('already released'),
    );
  });

  it('a handler that throws synchronously (not a hang) is still caught and releases the chain', async () => {
    let secondRan = false;
    queue.enqueue('chat1', () => {
      throw new Error('boom');
    });
    queue.enqueue('chat1', async () => {
      secondRan = true;
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(secondRan).toBe(true);
    expect(logger.error).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 'chat1' }),
      'Unhandled message error',
    );
  });
});
