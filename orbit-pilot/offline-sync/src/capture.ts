import type { PilotOutbox } from "./outbox.ts";
import type { EventAction, GeoPoint, ScanEventPayload, ScanType } from "./types.ts";

type CaptureBase = Omit<ScanEventPayload, "id" | "scan_type" | "event_action" | "device_timestamp"> & {
  id?: string;
  device_timestamp?: string;
};

export function requireLocation(point: GeoPoint): GeoPoint {
  if (!Number.isFinite(point.latitude) || !Number.isFinite(point.longitude)) {
    throw new Error("PILOT_QUEUE: location is required before enqueue");
  }
  if (Math.abs(point.latitude) > 90 || Math.abs(point.longitude) > 180) {
    throw new Error("PILOT_QUEUE: location is out of range");
  }
  return point;
}

function requireIds(input: CaptureBase): void {
  if (!input.tenant_id || !input.student_id || !input.bus_id || !input.trip_id) {
    throw new Error("PILOT_QUEUE: tenant_id, student_id, bus_id, and trip_id are required");
  }
  if (input.ble_zone !== 1 && input.ble_zone !== 2) {
    throw new Error("PILOT_QUEUE: ble_zone must be 1 or 2");
  }
  requireLocation(input.location);
}

function stamp(input: CaptureBase, scanType: ScanType, action: EventAction): Omit<ScanEventPayload, "id"> & { id?: string } {
  requireIds(input);
  return {
    ...input,
    scan_type: scanType,
    event_action: action,
    device_timestamp: input.device_timestamp ?? new Date().toISOString(),
  };
}

/**
 * Pilot write path. BLE pings and offboards hit SQLite first.
 * Never call Supabase from these functions.
 */
export class PilotCapture {
  constructor(private readonly outbox: PilotOutbox) {}

  async blePing(
    input: CaptureBase & { event_action?: Extract<EventAction, "Boarded" | "Zone_Detection"> },
  ): Promise<string> {
    return this.outbox.enqueue(
      "ble_ping",
      stamp(input, "BLE_Passive", input.event_action ?? "Zone_Detection"),
    );
  }

  async offboard(
    input: CaptureBase & {
      event_action?: Extract<EventAction, "Exited" | "Premature_Exit">;
      scan_type?: Extract<ScanType, "BLE_Passive" | "Manual_Pilot" | "RFID_Tap" | "NFC_Tap">;
    },
  ): Promise<string> {
    const scanType = input.scan_type ?? "Manual_Pilot";
    return this.outbox.enqueue(
      "offboard",
      stamp(input, scanType, input.event_action ?? "Exited"),
    );
  }
}
