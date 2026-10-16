import { createClient } from "npm:@supabase/supabase-js@2.57.0";
// One-off iCalendar export. NOT a subscribed feed or ongoing Google/Apple/Microsoft sync.
// Gateway JWT is required; RLS enforces tenant, parent, Pin and Satellite visibility.
const json = (message: string, code: number) => new Response(JSON.stringify({ error: message }), {
 status: code, headers: { "content-type": "application/json", "cache-control": "no-store" }
});
const icsEscape = (value: string) => value.replace(/\\/g, "\\\\").replace(/\r?\n/g, "\\n").replace(/[,;]/g, (x) => "\\" + x);
const toUtc = (v: string) => new Date(v).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const asDate = (v: string) => v.replace(/-/g, "");
Deno.serve(async (req: Request): Promise<Response> => {
 if (req.method !== "GET") return json("Method not allowed", 405);
 const auth = req.headers.get("authorization") ?? "";
 const token = auth.replace(/^Bearer\s+/i, "").trim();
 if (!token || token === auth) return json("Authorization required", 401);
 const id = new URL(req.url).searchParams.get("event_id") ?? "";
 if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(id))
  return json("Valid event_id required", 400);
 const url = Deno.env.get("SUPABASE_URL");
 const key = Deno.env.get("SUPABASE_ANON_KEY");
 if (!url || !key) return json("Calendar configuration missing", 503);
 const db = createClient(url, key, { auth: { persistSession: false },
  global: { headers: { Authorization: auth } } });
 const { data: userData, error: userError } = await db.auth.getUser(token);
 if (userError || !userData.user) return json("Invalid session", 401);
 const { data: event, error } = await db.from("orbit_calendar_events")
  .select("id,event_type,title,event_date,starts_at,ends_at,status,updated_at").eq("id", id).maybeSingle();
 if (error) return json("Calendar lookup unavailable", 503);
 if (!event) return json("Event not found", 404);
 const date = asDate(event.event_date);
 const beginning = event.starts_at ? "DTSTART:" + toUtc(event.starts_at) : "DTSTART;VALUE=DATE:" + date;
 const ending = event.ends_at ? ["DTEND:" + toUtc(event.ends_at)] :
  event.starts_at ? [] : ["DTEND;VALUE=DATE:" +
   asDate(new Date(event.event_date + "T12:00:00Z").toISOString().slice(0,10)
    .replace(/^/, "").replace(/$/, ""))];
 // For all-day events RFC5545 DTEND is EXCLUSIVE (next day).
 if (!event.starts_at) ending[0] = "DTEND;VALUE=DATE:" +
  new Date(Date.parse(event.event_date + "T00:00:00Z") + 86400000).toISOString().slice(0,10).replace(/-/g,"");
 const lines = ["BEGIN:VCALENDAR","VERSION:2.0","PRODID:-//Orbit Systems//Orbit Calendar//EN",
  "CALSCALE:GREGORIAN","METHOD:PUBLISH","BEGIN:VEVENT",
  "UID:" + event.id + "@orbitsafety.systems",
  "DTSTAMP:" + toUtc(new Date().toISOString()),
  beginning, ...ending,
  "SUMMARY:" + icsEscape(event.title),
  "CATEGORIES:" + (event.event_type === "field_trip" ? "FIELD TRIP" : "SCHOOL EVENT"),
  "STATUS:" + (event.status === "cancelled" ? "CANCELLED" : "CONFIRMED"),
  "END:VEVENT","END:VCALENDAR"];
 return new Response(lines.join("\r\n") + "\r\n", { status: 200,
  headers: { "content-type": "text/calendar; charset=utf-8",
   "content-disposition": 'attachment; filename="orbit-event.ics"',
   "cache-control": "private, no-store", "x-content-type-options": "nosniff" }});
});
