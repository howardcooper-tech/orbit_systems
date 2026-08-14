import { migratePilotOutbox } from "./schema.ts";
import { newEventId } from "./id.ts";
import type { OutboxKind, OutboxRow, ScanEventPayload, SqliteDb } from "./types.ts";

const SQL = {
  insert: `INSERT INTO pilot_outbox (id, kind, payload, status, attempt_count, next_attempt_at, last_error, created_at, synced_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  due: `SELECT id, kind, payload, status, attempt_count, next_attempt_at, last_error, created_at, synced_at FROM pilot_outbox WHERE status IN ('pending', 'inflight') AND next_attempt_at <= ? ORDER BY created_at ASC LIMIT ?`,
  inflight: `UPDATE pilot_outbox SET status = 'inflight' WHERE id = ?`,
  synced: `UPDATE pilot_outbox SET status = 'synced', synced_at = ?, last_error = NULL WHERE id = ?`,
  dead: `UPDATE pilot_outbox SET status = 'dead', last_error = ? WHERE id = ?`,
  retry: `UPDATE pilot_outbox SET status = 'pending', attempt_count = ?, next_attempt_at = ?, last_error = ? WHERE id = ?`,
  pendingCount: `SELECT COUNT(*) AS count FROM pilot_outbox WHERE status IN ('pending', 'inflight')`,
} as const;

interface StoredOutbox {
  id: string;
  kind: OutboxKind;
  payload: string;
  status: OutboxRow["status"];
  attempt_count: number;
  next_attempt_at: number;
  last_error: string | null;
  created_at: number;
  synced_at: number | null;
}

function hydrate(row: StoredOutbox): OutboxRow {
  return {
    ...row,
    payload: JSON.parse(row.payload) as ScanEventPayload,
  };
}

export class PilotOutbox {
  constructor(private readonly db: SqliteDb) {}

  async init(): Promise<void> {
    await migratePilotOutbox(this.db);
  }

  async enqueue(kind: OutboxKind, payload: Omit<ScanEventPayload, "id"> & { id?: string }): Promise<string> {
    const id = payload.id ?? newEventId();
    const now = Date.now();
    const full: ScanEventPayload = { ...payload, id };
    await this.db.exec(SQL.insert, [
      id,
      kind,
      JSON.stringify(full),
      "pending",
      0,
      now,
      null,
      now,
      null,
    ]);
    return id;
  }

  async due(limit = 25): Promise<OutboxRow[]> {
    const rows = await this.db.all<StoredOutbox>(SQL.due, [Date.now(), limit]);
    return rows.map(hydrate);
  }

  async markInflight(id: string): Promise<void> {
    await this.db.exec(SQL.inflight, [id]);
  }

  async markSynced(id: string): Promise<void> {
    await this.db.exec(SQL.synced, [Date.now(), id]);
  }

  async markDead(id: string, error: string): Promise<void> {
    await this.db.exec(SQL.dead, [error.slice(0, 500), id]);
  }

  async markRetry(id: string, attemptCount: number, nextAttemptAt: number, error: string): Promise<void> {
    await this.db.exec(SQL.retry, [attemptCount, nextAttemptAt, error.slice(0, 500), id]);
  }

  async pendingCount(): Promise<number> {
    const rows = await this.db.all<{ count: number }>(SQL.pendingCount);
    return Number(rows[0]?.count ?? 0);
  }
}
