export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": Deno.env.get("ORBIT_CORS_ORIGIN") ?? "https://id-preview--1f86b95b-2099-4abd-934d-27e64391c39b.lovable.app",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
