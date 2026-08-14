import { createBrowserNetworkMonitor } from "./network.ts";
import { PilotCapture } from "./capture.ts";
import { PilotOutbox } from "./outbox.ts";
import { createSupabaseScanClient, PilotSyncEngine } from "./uploader.ts";
import { createMemorySqlite } from "./memory-db.ts";
import type { NetworkMonitor, SqliteDb } from "./types.ts";

export { createExpoSqliteAdapter } from "./expo-sqlite.ts";
export { createMemorySqlite } from "./memory-db.ts";
export { createBrowserNetworkMonitor } from "./network.ts";
export { PilotCapture } from "./capture.ts";
export { PilotOutbox } from "./outbox.ts";
export { PilotSyncEngine, createSupabaseScanClient, toStudentScanRow } from "./uploader.ts";
export { nextBackoffMs, staggerDelayMs } from "./backoff.ts";
export { migratePilotOutbox, PILOT_OUTBOX_SCHEMA } from "./schema.ts";
export type {
  BackoffConfig,
  EventAction,
  GeoPoint,
  NetworkMonitor,
  OutboxKind,
  OutboxRow,
  ScanEventPayload,
  ScanType,
  SqliteDb,
} from "./types.ts";

export interface StartPilotOfflineSyncOptions {
  db?: SqliteDb;
  supabase: {
    from: (table: string) => {
      insert: (row: Record<string, unknown>) => Promise<{ error: { message: string; code?: string } | null }>;
    };
  };
  network?: NetworkMonitor;
}

/**
 * Wire the Pilot tablet:
 *   const { capture, engine } = await startPilotOfflineSync({ supabase, db: createExpoSqliteAdapter(sqlite) });
 *   await capture.blePing({ tenant_id, student_id, bus_id, trip_id, ble_zone: 1, location });
 *   await capture.offboard({ tenant_id, student_id, bus_id, trip_id, ble_zone: 1, location });
 * Replay starts automatically when LTE/5G returns.
 */
export async function startPilotOfflineSync(options: StartPilotOfflineSyncOptions) {
  const db = options.db ?? createMemorySqlite();
  const outbox = new PilotOutbox(db);
  await outbox.init();

  const capture = new PilotCapture(outbox);
  const engine = new PilotSyncEngine(
    outbox,
    createSupabaseScanClient(options.supabase),
    options.network ?? createBrowserNetworkMonitor(),
  );
  engine.start();

  return { outbox, capture, engine };
}
