import type { PilotOutbox } from "./outbox.ts";
import type { EventAction, GeoPoint, ScanEventPayload, ScanType } from "./types.ts";

type CaptureBase = Omit<ScanEventPayload, "id" | "scan_type" | "event_action" | "device_timestamp"> & {
  id?: string;
  device_timestamp?: string;
};

function stamp(input: CaptureBase, scanType: ScanType, action: EventAction): Omit<ScanEventPayload, "id"> & { id?: string } {
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

export function requireLocation(point: GeoPoint): GeoPoint {
  if (!Number.isFinite(point.latitude) || !Number.isFinite(point.longitude)) {
    throw new Error("PILOT_QUEUE: location is required before enqueue");
  }
  return point;
}
