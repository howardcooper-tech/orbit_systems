export const PILOT_OUTBOX_SCHEMA = `
CREATE TABLE IF NOT EXISTS pilot_outbox (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('ble_ping', 'offboard')),
  payload TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'inflight', 'synced', 'dead')),
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  synced_at INTEGER
);

CREATE INDEX IF NOT EXISTS pilot_outbox_due_idx
  ON pilot_outbox (status, next_attempt_at);

CREATE INDEX IF NOT EXISTS pilot_outbox_kind_status_idx
  ON pilot_outbox (kind, status);
`;

export async function migratePilotOutbox(db: { exec: (sql: string) => Promise<void> }): Promise<void> {
  await db.exec(PILOT_OUTBOX_SCHEMA);
}
