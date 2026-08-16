import { DEFAULT_BACKOFF, type BackoffConfig } from "./types.ts";

/**
 * Staggered exponential backoff: 1s * 2^attempt, capped at 5 minutes, with jitter.
 * attemptCount 0 => ~1s. Does not exceed maxMs after jitter.
 */
export function nextBackoffMs(
  attemptCount: number,
  config: BackoffConfig = DEFAULT_BACKOFF,
  random: () => number = Math.random,
): number {
  const exp = Math.min(config.maxMs, config.baseMs * config.factor ** Math.max(0, attemptCount));
  const span = Math.min(1, Math.max(0, config.jitter));
  const jitter = 1 - span + random() * 2 * span;
  return Math.max(0, Math.min(config.maxMs, Math.round(exp * jitter)));
}

export function staggerDelayMs(index: number, config: BackoffConfig = DEFAULT_BACKOFF): number {
  return Math.max(0, index) * config.staggerMs;
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
