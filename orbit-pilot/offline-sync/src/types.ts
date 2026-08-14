export type OutboxKind = "ble_ping" | "offboard";
export type OutboxStatus = "pending" | "inflight" | "synced" | "dead";

export type ScanType =
  | "BLE_Passive"
  | "RFID_Tap"
  | "NFC_Tap"
  | "Manual_Pilot"
  | "Manual_Teacher";

export type EventAction =
  | "Boarded"
  | "Exited"
  | "Premature_Exit"
  | "Transfer"
  | "Halo_Verified"
  | "Zone_Detection";

export interface GeoPoint {
  latitude: number;
  longitude: number;
}

export interface ScanEventPayload {
  id: string;
  tenant_id: string;
  student_id: string;
  bus_id: string;
  trip_id: string;
  waypoint_id?: string | null;
  scan_type: ScanType;
  event_action: EventAction;
  ble_zone: 1 | 2;
  location: GeoPoint;
  is_tap_recovery?: boolean;
  device_timestamp: string;
}

export interface OutboxRow {
  id: string;
  kind: OutboxKind;
  payload: ScanEventPayload;
  status: OutboxStatus;
  attempt_count: number;
  next_attempt_at: number;
  last_error: string | null;
  created_at: number;
  synced_at: number | null;
}

export interface SqliteDb {
  exec(sql: string, params?: unknown[]): Promise<void>;
  all<T>(sql: string, params?: unknown[]): Promise<T[]>;
}

export interface NetworkMonitor {
  isOnline(): boolean;
  subscribe(listener: (online: boolean) => void): () => void;
}

export interface BackoffConfig {
  baseMs: number;
  maxMs: number;
  factor: number;
  staggerMs: number;
}

export const DEFAULT_BACKOFF: BackoffConfig = {
  baseMs: 1_000,
  maxMs: 5 * 60_000,
  factor: 2,
  staggerMs: 350,
};
