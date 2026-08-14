import type { SqliteDb } from "./types.ts";

interface StoredRow {
  id: string;
  kind: string;
  payload: string;
  status: string;
  attempt_count: number;
  next_attempt_at: number;
  last_error: string | null;
  created_at: number;
  synced_at: number | null;
}

function asRecord(params: unknown[]): Record<string, unknown> {
  const [id, kind, payload, status, attempt, nextAt, lastError, created, synced] = params;
  return {
    id,
    kind,
    payload,
    status,
    attempt_count: attempt,
    next_attempt_at: nextAt,
    last_error: lastError ?? null,
    created_at: created,
    synced_at: synced ?? null,
  };
}

/** Drop-in SQLite stand-in for unit tests and first wiring. Swap for expo-sqlite on device. */
export function createMemorySqlite(): SqliteDb {
  const rows = new Map<string, StoredRow>();

  return {
    async exec(sql: string, params: unknown[] = []): Promise<void> {
      const normalized = sql.replace(/\s+/g, " ").trim();

      if (normalized.startsWith("CREATE TABLE") || normalized.startsWith("CREATE INDEX")) {
        return;
      }

      if (normalized.startsWith("INSERT INTO pilot_outbox")) {
        const rec = asRecord(params) as StoredRow;
        rows.set(rec.id, rec);
        return;
      }

      if (normalized.startsWith("UPDATE pilot_outbox SET status = 'inflight'")) {
        const [id] = params as [string];
        const row = rows.get(id);
        if (row && (row.status === "pending" || row.status === "inflight")) {
          row.status = "inflight";
        }
        return;
      }

      if (normalized.startsWith("UPDATE pilot_outbox SET status = 'synced'")) {
        const [syncedAt, id] = params as [number, string];
        const row = rows.get(id);
        if (row) {
          row.status = "synced";
          row.synced_at = syncedAt;
          row.last_error = null;
        }
        return;
      }

      if (normalized.startsWith("UPDATE pilot_outbox SET status = 'dead'")) {
        const [err, id] = params as [string, string];
        const row = rows.get(id);
        if (row) {
          row.status = "dead";
          row.last_error = err;
        }
        return;
      }

      if (normalized.startsWith("UPDATE pilot_outbox SET status = 'pending'")) {
        const [attempt, nextAt, err, id] = params as [number, number, string, string];
        const row = rows.get(id);
        if (row) {
          row.status = "pending";
          row.attempt_count = attempt;
          row.next_attempt_at = nextAt;
          row.last_error = err;
        }
      }
    },

    async all<T>(sql: string, params: unknown[] = []): Promise<T[]> {
      const normalized = sql.replace(/\s+/g, " ").trim();
      if (normalized.startsWith("SELECT") && normalized.includes("status IN ('pending', 'inflight')")) {
        const now = Number(params[0]);
        const limit = Number(params[1] ?? 25);
        return [...rows.values()]
          .filter((r) => (r.status === "pending" || r.status === "inflight") && r.next_attempt_at <= now)
          .sort((a, b) => a.created_at - b.created_at)
          .slice(0, limit) as T[];
      }
      if (normalized.includes("COUNT(*)")) {
        const pending = [...rows.values()].filter((r) => r.status === "pending" || r.status === "inflight").length;
        return [{ count: pending }] as T[];
      }
      return [...rows.values()] as T[];
    },
  };
}
