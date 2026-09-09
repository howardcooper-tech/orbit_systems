import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const CORS_ORIGIN = Deno.env.get("ORBIT_CORS_ORIGIN") ?? "https://id-preview--1f86b95b-2099-4abd-934d-27e64391c39b.lovable.app";

if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error("Missing required Supabase runtime environment variables.");
}

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": CORS_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};

const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CATEGORIES = new Set([
  "UNSAFE_DRIVING",
  "DRIVER_DISTRACTION",
  "DRIVER_CABIN_INTERACTION",
  "VEHICLE_HAZARD",
  "BULLYING",
  "FIGHTING",
  "DRUGS_WEAPONS",
  "HARASSMENT",
  "MEDICAL_SAFETY",
  "OTHER",
]);
const ALLOWED_MIMES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/heic",
  "video/mp4",
  "video/quicktime",
  "video/webm",
]);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function asUuid(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const v = value.trim();
  return UUID_RE.test(v) ? v : null;
}

function asString(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const v = value.trim();
  if (!v || v.length > max) return null;
  return v;
}

function randomHex(bytes = 32): string {
  const data = new Uint8Array(bytes);
  crypto.getRandomValues(data);
  return Array.from(data, (b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(value: string): Promise<string> {
  const data = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

async function authenticateReviewer(req: Request) {
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.toLowerCase().startsWith("bearer ")) return null;
  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) return null;
  return { client, user: data.user };
}

async function submitReport(body: Record<string, unknown>): Promise<Response> {
  const studentId = asUuid(body.student_id);
  const pin = typeof body.pin === "string" ? body.pin.trim() : "";
  const category = typeof body.category === "string" ? body.category.trim().toUpperCase() : "";
  const summary = asString(body.summary, 180);
  const details = body.details == null || body.details === "" ? null : asString(body.details, 4000);
  const clientReportedAt = typeof body.client_reported_at === "string" && !Number.isNaN(Date.parse(body.client_reported_at))
    ? new Date(body.client_reported_at).toISOString()
    : null;

  if (!studentId || !pin || pin.length > 32 || !CATEGORIES.has(category) || !summary || (body.details && !details)) {
    return json({ error: "SAFETY_REPORT_DENIED" }, 400);
  }

  const { data: student } = await admin
    .from("students")
    .select("id, tenant_id")
    .eq("id", studentId)
    .is("archived_at", null)
    .maybeSingle();
  if (!student) return json({ error: "SAFETY_REPORT_DENIED" }, 403);

  const tenMinutesAgo = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const { count: recentFailures } = await admin
    .from("pin_safety_auth_attempts")
    .select("id", { count: "exact", head: true })
    .eq("student_id", studentId)
    .eq("succeeded", false)
    .gte("attempted_at", tenMinutesAgo);
  if ((recentFailures ?? 0) >= 8) return json({ error: "SAFETY_REPORT_RATE_LIMITED" }, 429);

  const { data: pinValid, error: pinError } = await admin.rpc("verify_student_pin", {
    p_student_id: studentId,
    p_pin: pin,
  });
  const valid = !pinError && pinValid === true;

  await admin.from("pin_safety_auth_attempts").insert({
    tenant_id: student.tenant_id,
    student_id: studentId,
    succeeded: valid,
  });
  if (!valid) return json({ error: "SAFETY_REPORT_DENIED" }, 403);

  const uploadToken = randomHex(32);
  const uploadTokenHash = await sha256Hex(uploadToken);
  const { data, error } = await admin.rpc("create_pin_safety_report_server", {
    p_student_id: studentId,
    p_category: category,
    p_summary: summary,
    p_details: details,
    p_client_reported_at: clientReportedAt,
    p_upload_token_hash: uploadTokenHash,
  });
  if (error || !data?.ok) {
    console.error("create_pin_safety_report_server", error?.message ?? data);
    return json({ error: "SAFETY_REPORT_DENIED" }, 403);
  }

  return json({ ...data, upload_token: uploadToken, single_blind: true, dvr_provider_status: "PENDING_PROVIDER" }, 201);
}

async function createUpload(body: Record<string, unknown>): Promise<Response> {
  const reportId = asUuid(body.report_id);
  const uploadToken = typeof body.upload_token === "string" ? body.upload_token.trim() : "";
  const mimeType = typeof body.mime_type === "string" ? body.mime_type.trim().toLowerCase() : "";
  const byteSize = Number(body.byte_size);
  const durationMs = body.duration_ms == null ? null : Number(body.duration_ms);

  if (!reportId || uploadToken.length < 32 || !ALLOWED_MIMES.has(mimeType) || !Number.isInteger(byteSize) || byteSize < 1) {
    return json({ error: "SAFETY_UPLOAD_DENIED" }, 400);
  }
  if (mimeType.startsWith("video/") && (!Number.isInteger(durationMs) || durationMs! < 1 || durationMs! > 30000)) {
    return json({ error: "SAFETY_UPLOAD_DENIED" }, 400);
  }

  const tokenHash = await sha256Hex(uploadToken);
  const { data: allocation, error: allocationError } = await admin.rpc("allocate_pin_safety_upload_server", {
    p_report_id: reportId,
    p_token_hash: tokenHash,
    p_mime_type: mimeType,
    p_byte_size: byteSize,
    p_duration_ms: durationMs,
  });
  if (allocationError || !allocation?.ok) {
    console.error("allocate_pin_safety_upload_server", allocationError?.message ?? allocation);
    return json({ error: "SAFETY_UPLOAD_DENIED" }, 403);
  }

  const { data: signed, error: signError } = await admin.storage.from(allocation.bucket).createSignedUploadUrl(allocation.path);
  if (signError || !signed) {
    await admin.from("pin_safety_evidence").update({ evidence_status: "FAILED" }).eq("id", allocation.evidence_id);
    return json({ error: "SAFETY_UPLOAD_UNAVAILABLE" }, 502);
  }
  return json({
    ok: true,
    report_id: reportId,
    evidence_id: allocation.evidence_id,
    bucket: allocation.bucket,
    path: allocation.path,
    signed_upload_url: signed.signedUrl,
    signed_upload_token: signed.token,
    expires_in_seconds: 7200,
  });
}

async function finalizeUpload(body: Record<string, unknown>): Promise<Response> {
  const reportId = asUuid(body.report_id);
  const evidenceId = asUuid(body.evidence_id);
  const uploadToken = typeof body.upload_token === "string" ? body.upload_token.trim() : "";
  if (!reportId || !evidenceId || uploadToken.length < 32) return json({ error: "SAFETY_UPLOAD_DENIED" }, 400);

  const tokenHash = await sha256Hex(uploadToken);
  const { data: evidence } = await admin
    .from("pin_safety_evidence")
    .select("id, report_id, storage_bucket, storage_path, mime_type, byte_size")
    .eq("id", evidenceId)
    .eq("report_id", reportId)
    .maybeSingle();
  if (!evidence?.storage_bucket || !evidence.storage_path) return json({ error: "SAFETY_UPLOAD_DENIED" }, 403);

  const slash = evidence.storage_path.lastIndexOf("/");
  const folder = slash >= 0 ? evidence.storage_path.slice(0, slash) : "";
  const fileName = slash >= 0 ? evidence.storage_path.slice(slash + 1) : evidence.storage_path;
  const { data: listed, error: listError } = await admin.storage
    .from(evidence.storage_bucket)
    .list(folder, { limit: 10, search: fileName });
  if (listError) {
    console.error("storage list finalize", listError.message);
    return json({ error: "SAFETY_UPLOAD_UNAVAILABLE" }, 502);
  }
  const objectRow = (listed ?? []).find((item) => item.id !== null && item.name === fileName);
  if (!objectRow) return json({ error: "SAFETY_UPLOAD_NOT_FOUND" }, 409);

  const metadata = (objectRow.metadata ?? {}) as Record<string, unknown>;
  const actualMime = typeof metadata.mimetype === "string"
    ? metadata.mimetype.toLowerCase()
    : typeof metadata.contentType === "string"
      ? metadata.contentType.toLowerCase()
      : evidence.mime_type;
  const actualSizeRaw = metadata.size;
  const actualSize = typeof actualSizeRaw === "number" ? actualSizeRaw : Number(actualSizeRaw);
  if (!actualMime || !Number.isFinite(actualSize) || actualSize < 1) return json({ error: "SAFETY_UPLOAD_INVALID_OBJECT" }, 409);

  const { data, error } = await admin.rpc("finalize_pin_safety_upload_server", {
    p_report_id: reportId,
    p_evidence_id: evidenceId,
    p_token_hash: tokenHash,
    p_actual_mime_type: actualMime,
    p_actual_byte_size: Math.trunc(actualSize),
  });
  if (error || !data?.ok) {
    console.error("finalize_pin_safety_upload_server", error?.message ?? data);
    return json({ error: "SAFETY_UPLOAD_DENIED" }, 403);
  }
  return json(data);
}

async function reviewDownload(req: Request, body: Record<string, unknown>): Promise<Response> {
  const reviewer = await authenticateReviewer(req);
  if (!reviewer) return json({ error: "SAFETY_REVIEW_DENIED" }, 401);
  const reportId = asUuid(body.report_id);
  const evidenceId = asUuid(body.evidence_id);
  if (!reportId || !evidenceId) return json({ error: "SAFETY_REVIEW_DENIED" }, 400);

  const { data: access, error: accessError } = await reviewer.client.rpc("get_pin_safety_evidence_access", {
    p_report_id: reportId,
    p_evidence_id: evidenceId,
  });
  if (accessError || !access?.bucket || !access?.path) return json({ error: "SAFETY_REVIEW_DENIED" }, 403);

  const { error: auditError } = await reviewer.client.rpc("record_pin_safety_review_action", {
    p_report_id: reportId,
    p_event_type: "EVIDENCE_VIEWED",
    p_notes: null,
    p_new_status: null,
    p_metadata: { evidence_id: evidenceId, evidence_class: access.evidence_class },
  });
  if (auditError) return json({ error: "SAFETY_REVIEW_DENIED" }, 403);

  const { data: signed, error: signedError } = await admin.storage.from(access.bucket).createSignedUrl(access.path, 300);
  if (signedError || !signed?.signedUrl) return json({ error: "SAFETY_EVIDENCE_UNAVAILABLE" }, 502);
  return json({ ok: true, evidence_id: evidenceId, evidence_class: access.evidence_class, signed_url: signed.signedUrl, expires_in_seconds: 300 });
}

Deno.serve(async (req) => {
  const requestOrigin = req.headers.get("origin");
  if (requestOrigin && requestOrigin !== CORS_ORIGIN) {
    return json({ error: "ORIGIN_NOT_ALLOWED" }, 403);
  }

  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "INVALID_JSON" }, 400); }

  const action = typeof body.action === "string" ? body.action.trim().toLowerCase() : "";
  try {
    if (action === "submit_report") return await submitReport(body);
    if (action === "create_upload") return await createUpload(body);
    if (action === "finalize_upload") return await finalizeUpload(body);
    if (action === "review_download") return await reviewDownload(req, body);
    return json({ error: "UNKNOWN_ACTION" }, 400);
  } catch (error) {
    console.error("pin-safety-reporting unhandled", error);
    return json({ error: "SAFETY_SERVICE_ERROR" }, 500);
  }
});
