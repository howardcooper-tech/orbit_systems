// Local proposal only. This edit is not deployed. Staging keeps the previously
// deployed function until the owner approves this contract.
import { serve } from "https://deno.land/std@0.210.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.30.0";
import { bearerDecision, busWriteDecision, telemetryLog } from "./ownership.mjs";

const DUVAL_BOUNDS = {
  minLatitude: 30.13,
  maxLatitude: 30.56,
  minLongitude: -81.95,
  maxLongitude: -81.55,
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  throw new Error("Missing required Supabase runtime environment variables: SUPABASE_URL and SUPABASE_ANON_KEY");
}

function userClient(token: string) {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

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

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  const gate = bearerDecision(req.headers.get("Authorization"));
  if (!gate.ok) {
    console.error(JSON.stringify(telemetryLog("telemetry_unauthorized", { status: gate.status })));
    if (gate.code) return json({ code: gate.code, message: gate.message }, gate.status);
    return json({ error: gate.error }, gate.status);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON payload." }, 400);
  }

  const validation = validateTelemetryPayload(body);
  if (!validation.valid) {
    return json({ errors: validation.errors }, 400);
  }

  const client = userClient(gate.token);
  const { data: userData, error: userError } = await client.auth.getUser(gate.token);
  if (userError || !userData.user) {
    console.error(JSON.stringify(telemetryLog("telemetry_unauthorized", { status: 401 })));
    return json({ code: "UNAUTHORIZED_INVALID_JWT_FORMAT", message: "Invalid JWT" }, 401);
  }

  const busId = validation.payload!.bus_id;
  const { data: bus, error: busError } = await client
    .from("buses")
    .select("id,assigned_pilot_id")
    .eq("id", busId)
    .maybeSingle();
  const decision = busWriteDecision({
    userId: userData.user.id,
    assignedPilotId: busError ? null : (bus?.assigned_pilot_id ?? null),
  });
  if (decision !== "allowed") {
    console.error(JSON.stringify(telemetryLog("telemetry_forbidden", { bus_id: busId, decision })));
    return json({ error: "Telemetry bus is not assigned to this caller." }, 403);
  }

  const row = prepareTelemetryRow(validation.payload!);
  const { error } = await client.from("bus_telemetry_logs").insert([row]);
  if (error) {
    console.error(JSON.stringify(telemetryLog("telemetry_insert_failed", { bus_id: busId, code: error.code ?? "unknown" })));
    return json({ error: "Unable to persist telemetry." }, 502);
  }

  return new Response(JSON.stringify({ success: true, data: row }), {
    status: 201,
    headers: { "Content-Type": "application/json" },
  });
});
