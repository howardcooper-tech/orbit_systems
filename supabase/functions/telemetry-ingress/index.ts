import { serve } from "https://deno.land/std@0.210.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.30.0";

const DUVAL_BOUNDS = {
  minLatitude: 30.13,
  maxLatitude: 30.56,
  minLongitude: -81.95,
  maxLongitude: -81.55,
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error("Missing required Supabase runtime environment variables: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY");
}

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: {
    persistSession: false,
  },
});

interface TelemetryPayload {
  bus_id: string;
  latitude: number;
  longitude: number;
  timestamp: string;
}

function toNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function validateTelemetryPayload(body: Record<string, unknown>) {
  const errors: string[] = [];

  const busId = typeof body.bus_id === "string" ? body.bus_id.trim() : "";
  if (!busId) {
    errors.push("Missing or invalid bus_id.");
  }

  const latitude = toNumber(body.latitude);
  if (latitude === null || latitude < -90 || latitude > 90) {
    errors.push("Missing or invalid latitude.");
  }

  const longitude = toNumber(body.longitude);
  if (longitude === null || longitude < -180 || longitude > 180) {
    errors.push("Missing or invalid longitude.");
  }

  const timestampString = typeof body.timestamp === "string" ? body.timestamp.trim() : "";
  const recordedAt = new Date(timestampString);
  if (!timestampString || Number.isNaN(recordedAt.valueOf())) {
    errors.push("Missing or invalid timestamp.");
  }

  if (errors.length > 0) {
    return { valid: false, errors };
  }

  const isInDuval =
    latitude! >= DUVAL_BOUNDS.minLatitude &&
    latitude! <= DUVAL_BOUNDS.maxLatitude &&
    longitude! >= DUVAL_BOUNDS.minLongitude &&
    longitude! <= DUVAL_BOUNDS.maxLongitude;

  if (!isInDuval) {
    errors.push("Coordinates are outside the allowed Duval County bounds.");
    return { valid: false, errors };
  }

  return {
    valid: true,
    payload: {
      bus_id: busId,
      latitude: latitude!,
      longitude: longitude!,
      timestamp: recordedAt.toISOString(),
    } as TelemetryPayload,
  };
}

function prepareTelemetryRow(payload: TelemetryPayload) {
  return {
    bus_id: payload.bus_id,
    recorded_at: payload.timestamp,
    position: {
      type: "Point",
      coordinates: [payload.longitude, payload.latitude],
    },
  };
}

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed." }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON payload." }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const validation = validateTelemetryPayload(body);
  if (!validation.valid) {
    return new Response(JSON.stringify({ errors: validation.errors }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const row = prepareTelemetryRow(validation.payload!);

  const { error } = await supabase.from("bus_telemetry_logs").insert([row]);
  if (error) {
    console.error("Telemetry insert error:", error);
    return new Response(JSON.stringify({ error: "Unable to persist telemetry." }), {
      status: 502,
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ success: true, data: row }), {
    status: 201,
    headers: { "Content-Type": "application/json" },
  });
});
