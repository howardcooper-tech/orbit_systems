import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, json } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error("Missing SUPABASE_URL, SUPABASE_ANON_KEY, or SUPABASE_SERVICE_ROLE_KEY");
}

interface Zone1Body {
  student_id?: unknown;
  trip_id?: unknown;
  stop_id?: unknown;
  waypoint_id?: unknown;
  latitude?: unknown;
  longitude?: unknown;
  device_timestamp?: unknown;
}

interface Zone1Result {
  ok: boolean;
  error?: string;
  replay?: boolean;
  scan_id?: string;
  trip_id?: string;
  bus_id?: string;
  student_id?: string;
  pilot_id?: string;
  waypoint_id?: string | null;
  ble_zone?: number;
  headshot_url?: string | null;
  parent_display_name?: string | null;
  channel?: string;
  topic?: string;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function asUuid(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return UUID_RE.test(trimmed) ? trimmed : null;
}

function asCoord(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function parseBody(body: Zone1Body) {
  const student_id = asUuid(body.student_id);
  const trip_id = asUuid(body.trip_id);
  const stop_id = body.stop_id == null || body.stop_id === "" ? null : asUuid(body.stop_id);
  const waypoint_id = body.waypoint_id == null || body.waypoint_id === "" ? null : asUuid(body.waypoint_id);
  const latitude = asCoord(body.latitude);
  const longitude = asCoord(body.longitude);
  const device_timestamp =
    typeof body.device_timestamp === "string" && body.device_timestamp.trim() !== ""
      ? body.device_timestamp.trim()
      : null;

  if (!student_id || !trip_id || latitude === null || longitude === null) {
    return { ok: false as const };
  }
  if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
    return { ok: false as const };
  }
  if (body.stop_id != null && body.stop_id !== "" && !stop_id) {
    return { ok: false as const };
  }
  if (body.waypoint_id != null && body.waypoint_id !== "" && !waypoint_id) {
    return { ok: false as const };
  }

  return {
    ok: true as const,
    student_id,
    trip_id,
    stop_id,
    waypoint_id,
    latitude,
    longitude,
    device_timestamp,
  };
}

async function flashPilotTablet(
  admin: ReturnType<typeof createClient>,
  result: Zone1Result,
): Promise<void> {
  if (!result.ok || !result.bus_id || !result.topic) return;

  const payload = {
    event: "zone1_custody",
    ble_zone: 1,
    scan_id: result.scan_id,
    trip_id: result.trip_id,
    bus_id: result.bus_id,
    student_id: result.student_id,
    pilot_id: result.pilot_id,
    waypoint_id: result.waypoint_id ?? null,
    headshot_url: result.headshot_url ?? null,
    parent_display_name: result.parent_display_name ?? null,
    channel: "student_scan_events",
  };

  const channel = admin.channel(result.topic, {
    config: { broadcast: { ack: true, self: false } },
  });

  try {
    const subscribed = await new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => resolve(false), 1500);
      channel.subscribe((status) => {
        if (status === "SUBSCRIBED") {
          clearTimeout(timer);
          resolve(true);
        }
      });
    });

    if (subscribed) {
      await channel.send({
        type: "broadcast",
        event: "zone1_custody",
        payload,
      });
    }
  } finally {
    await admin.removeChannel(channel);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "ZONE1_DENIED" }, 405);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return json({ error: "ZONE1_DENIED" }, 401);
  }

  let body: Zone1Body;
  try {
    body = await req.json();
  } catch {
    return json({ error: "ZONE1_DENIED" }, 400);
  }

  const parsed = parseBody(body);
  if (!parsed.ok) {
    return json({ error: "ZONE1_DENIED" }, 400);
  }

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) {
    return json({ error: "ZONE1_DENIED" }, 401);
  }

  const { data, error } = await userClient.rpc("parent_zone1_im_here", {
    p_student_id: parsed.student_id,
    p_trip_id: parsed.trip_id,
    p_latitude: parsed.latitude,
    p_longitude: parsed.longitude,
    p_stop_id: parsed.stop_id,
    p_waypoint_id: parsed.waypoint_id,
    p_device_timestamp: parsed.device_timestamp,
  });

  if (error) {
    console.error("parent_zone1_im_here rpc", error.message);
    return json({ error: "ZONE1_DENIED" }, 403);
  }

  const result = (data ?? {}) as Zone1Result;
  if (!result.ok) {
    return json({ error: "ZONE1_DENIED" }, 403);
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    await flashPilotTablet(admin, result);
  } catch (broadcastError) {
    console.error("zone1 realtime flash", broadcastError);
  }

  return json({
    ok: true,
    replay: Boolean(result.replay),
    scan_id: result.scan_id,
    bus_id: result.bus_id,
    trip_id: result.trip_id,
    ble_zone: 1,
    channel: "student_scan_events",
    topic: result.topic,
  });
});
