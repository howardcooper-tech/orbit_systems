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
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !SUPABASE_ANON_KEY) {
  throw new Error("Missing required Supabase runtime environment variables.");
}

// Service-role client: used ONLY after the caller has been independently
// verified below (bus lookup + resource-ownership check + the final
// insert). Never used to establish who the caller is.
const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const TELEMETRY_RATE_WINDOW_MS = 60_000;
const TELEMETRY_MAX_EVENTS_PER_WINDOW = 600;

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

function validateTelemetryPayload(body: Record<string, unknown>):
  | { valid: true; payload: TelemetryPayload }
  | { valid: false; errors: string[] } {
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
    return { valid: false, errors: ["Coordinates are outside the allowed Duval County bounds."] };
  }

  return {
    valid: true,
    payload: {
      bus_id: busId,
      latitude: latitude!,
      longitude: longitude!,
      timestamp: recordedAt.toISOString(),
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

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!token) {
    return new Response(JSON.stringify({ error: "Missing bearer token." }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Verify the caller against their OWN token. verify_jwt=true at the
  // platform level only guarantees *some* valid JWT was presented -- it
  // does not tell this function who the caller is, so that identity still
  // has to be established here before any resource-ownership check means
  // anything.
  const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: userData, error: userError } = await callerClient.auth.getUser(token);
  if (userError || !userData?.user) {
    return new Response(JSON.stringify({ error: "Invalid or expired session." }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }
  const callerId = userData.user.id;

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

  const { bus_id, latitude, longitude, timestamp } = validation.payload;

  // Resource-ownership check, and the server-verified source of tenant_id.
  // We do not trust a client-supplied tenant claim for this write; we
  // derive it from the bus row itself.
  const { data: bus, error: busError } = await adminClient
    .from("buses")
    .select("id, tenant_id, assigned_pilot_id, contractor_id")
    .eq("id", bus_id)
    .maybeSingle();

  if (busError || !bus) {
    return new Response(JSON.stringify({ error: "Bus not found." }), {
      status: 404,
      headers: { "Content-Type": "application/json" },
    });
  }

  const { data: staffProfile } = await adminClient
    .from("staff_profiles")
    .select("role, contractor_id")
    .eq("id", callerId)
    .maybeSingle();

  const isAssignedPilot = bus.assigned_pilot_id === callerId;
  const isAuthorizedHalo =
    staffProfile?.role === "Halo" && staffProfile.contractor_id !== null &&
    staffProfile.contractor_id === bus.contractor_id;

  if (!isAssignedPilot && !isAuthorizedHalo) {
    return new Response(
      JSON.stringify({ error: "Not authorized to report telemetry for this bus." }),
      { status: 403, headers: { "Content-Type": "application/json" } }
    );
  }

  const rateWindowStart = new Date(Date.now() - TELEMETRY_RATE_WINDOW_MS).toISOString();
  const { count: recentEventCount, error: rateLimitError } = await adminClient
    .from("bus_telemetry_logs")
    .select("id", { count: "exact", head: true })
    .eq("bus_id", bus_id)
    .gte("synced_at", rateWindowStart);

  if (rateLimitError) {
    console.error("Telemetry rate-limit check error:", rateLimitError);
    return new Response(JSON.stringify({ error: "Unable to verify telemetry ingress rate." }), {
      status: 503,
      headers: { "Content-Type": "application/json", "Retry-After": "5" },
    });
  }

  if ((recentEventCount ?? 0) >= TELEMETRY_MAX_EVENTS_PER_WINDOW) {
    return new Response(JSON.stringify({ error: "Telemetry ingress rate exceeded." }), {
      status: 429,
      headers: { "Content-Type": "application/json", "Retry-After": "60" },
    });
  }

  const row = {
    bus_id,
    location: `SRID=4326;POINT(${longitude} ${latitude})`,
    device_timestamp: timestamp,
    recorded_at: timestamp,
    tenant_id: bus.tenant_id,
  };

  const { error: insertError } = await adminClient.from("bus_telemetry_logs").insert([row]);
  if (insertError) {
    console.error("Telemetry insert error:", insertError);
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
