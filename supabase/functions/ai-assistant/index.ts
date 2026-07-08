import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const MODEL = Deno.env.get("ANTHROPIC_MODEL") ?? "claude-sonnet-4-5";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_json" }, 400); }
  const action = String(body.action ?? "chat");
  if (action !== "chat") return json({ error: "unknown_action" }, 400);

  const { data: allowed } = await supabase.rpc("nx_check_rate", {
    p_user: user.id, p_action: "ai_chat", p_limit: 20, p_window_seconds: 3600,
  });
  if (allowed === false) return json({ error: "rate_limited" }, 429);

  const system = String(body.system ?? "").slice(0, 8_000);
  const messages = Array.isArray(body.messages) ? body.messages.slice(-20) : [];
  if (!messages.length) return json({ error: "messages_required" }, 400);

  if (!ANTHROPIC_KEY) {
    // No key configured yet — degrade gracefully instead of the client hitting
    // api.anthropic.com directly (which can never work from a browser: no key,
    // no CORS allowance). Mirrors email-relay's "simulated" fallback pattern.
    return json({
      ok: true,
      simulated: true,
      text: "AI Assistant isn't connected yet — ask an admin to set the ANTHROPIC_API_KEY secret on the ai-assistant Edge Function to enable live answers.",
    });
  }

  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": ANTHROPIC_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({ model: MODEL, max_tokens: 1000, system, messages }),
    });
    const data = await res.json();
    if (!res.ok) return json({ error: data?.error?.message ?? `anthropic_${res.status}` }, 502);
    const text = data?.content?.[0]?.text ?? "";
    return json({ ok: true, simulated: false, text });
  } catch (e) {
    return json({ error: String(e).slice(0, 300) }, 502);
  }
});
