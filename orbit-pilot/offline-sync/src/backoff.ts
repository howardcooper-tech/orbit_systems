import { DEFAULT_BACKOFF, type BackoffConfig } from "./types.ts";

export function nextBackoffMs(attemptCount: number, config: BackoffConfig = DEFAULT_BACKOFF): number {
  const exp = Math.min(
    config.maxMs,
    config.baseMs * config.factor ** Math.max(0, attemptCount),
  );
  const jitter = 0.5 + Math.random();
  return Math.round(exp * jitter);
}

export function staggerDelayMs(index: number, config: BackoffConfig = DEFAULT_BACKOFF): number {
  return index * config.staggerMs;
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
