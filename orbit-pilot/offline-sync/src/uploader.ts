import { nextBackoffMs, sleep, staggerDelayMs } from "./backoff.ts";
import type { PilotOutbox } from "./outbox.ts";
import type { BackoffConfig, NetworkMonitor, OutboxRow, ScanEventPayload } from "./types.ts";
import { DEFAULT_BACKOFF } from "./types.ts";

export interface ScanInsertClient {
  insertScanEvent(row: Record<string, unknown>): Promise<{ ok: true } | { ok: false; status?: number; message: string }>;
}

export function toStudentScanRow(payload: ScanEventPayload): Record<string, unknown> {
  const { longitude, latitude } = payload.location;
  return {
    id: payload.id,
    tenant_id: payload.tenant_id,
    student_id: payload.student_id,
    bus_id: payload.bus_id,
    trip_id: payload.trip_id,
    waypoint_id: payload.waypoint_id ?? null,
    scan_type: payload.scan_type,
    event_action: payload.event_action,
    ble_zone: payload.ble_zone,
    location_at_scan: `SRID=4326;POINT(${longitude} ${latitude})`,
    is_tap_recovery: payload.is_tap_recovery ?? false,
    device_timestamp: payload.device_timestamp,
  };
}

export function createSupabaseScanClient(supabase: {
  from: (table: string) => {
    insert: (row: Record<string, unknown>) => Promise<{ error: { message: string; code?: string } | null }>;
  };
}): ScanInsertClient {
  return {
    async insertScanEvent(row) {
      const { error } = await supabase.from("student_scan_events").insert(row);
      if (!error) return { ok: true };
      const permanent = /23|22|42501|PGRST/i.test(`${error.code ?? ""} ${error.message}`);
      return {
        ok: false,
        status: permanent ? 400 : 503,
        message: error.message,
      };
    },
  };
}

export class PilotSyncEngine {
  private running = false;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private unsubscribe: (() => void) | null = null;

  constructor(
    private readonly outbox: PilotOutbox,
    private readonly client: ScanInsertClient,
    private readonly network: NetworkMonitor,
    private readonly backoff: BackoffConfig = DEFAULT_BACKOFF,
    private readonly idlePollMs = 2_000,
  ) {}

  start(): void {
    if (this.running) return;
    this.running = true;
    this.unsubscribe = this.network.subscribe((online) => {
      if (online) void this.drain();
    });
    void this.loop();
  }

  stop(): void {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
    this.unsubscribe?.();
    this.unsubscribe = null;
  }

  async drain(): Promise<void> {
    if (!this.network.isOnline()) return;

    const batch = await this.outbox.due(25);
    for (let i = 0; i < batch.length; i += 1) {
      if (!this.running || !this.network.isOnline()) return;
      await sleep(staggerDelayMs(i, this.backoff));
      await this.uploadOne(batch[i]);
    }
  }

  private async loop(): Promise<void> {
    while (this.running) {
      try {
        await this.drain();
      } catch {
        // stay alive; next idle tick retries
      }
      await this.idle();
    }
  }

  private idle(): Promise<void> {
    return new Promise((resolve) => {
      this.timer = setTimeout(resolve, this.idlePollMs);
    });
  }

  private async uploadOne(row: OutboxRow): Promise<void> {
    await this.outbox.markInflight(row.id);
    const result = await this.client.insertScanEvent(toStudentScanRow(row.payload));

    if (result.ok) {
      await this.outbox.markSynced(row.id);
      return;
    }

    if (result.status && result.status >= 400 && result.status < 500 && result.status !== 408 && result.status !== 429) {
      await this.outbox.markDead(row.id, result.message);
      return;
    }

    const attempt = row.attempt_count + 1;
    const wait = nextBackoffMs(attempt, this.backoff);
    await this.outbox.markRetry(row.id, attempt, Date.now() + wait, result.message);
  }
}
