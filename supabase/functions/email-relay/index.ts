import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("EMAIL_FROM") ?? "NexCore ERP <onboarding@resend.dev>";

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

async function sha256(text: string): Promise<string> {
  const data = new TextEncoder().encode(text);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hash)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sendViaResend(to: string, subject: string, html: string) {
  if (!RESEND_KEY) return { simulated: true, id: null };
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, html }),
  });
  if (!res.ok) throw new Error(`Resend ${res.status}: ${await res.text()}`);
  const data = await res.json();
  return { simulated: false, id: data.id ?? null };
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
  const action = String(body.action ?? "");

  try {
    if (action === "send_email") {
      const to = String(body.to ?? "").trim();
      const subject = String(body.subject ?? "").slice(0, 200);
      const html = String(body.html ?? body.body ?? "").slice(0, 50_000);
      if (!to || !subject) return json({ error: "to_and_subject_required" }, 400);
      const result = await sendViaResend(to, subject, html || "<p>(no body)</p>");
      await supabase.from("nx_email_log").insert({
        sent_by: user.id, recipient: to, subject,
        provider: result.simulated ? "simulated" : "resend",
        provider_id: result.id, status: result.simulated ? "simulated" : "sent",
      });
      return json({ ok: true, simulated: result.simulated, id: result.id });
    }

    if (action === "send_otp") {
      const code = String(Math.floor(100000 + Math.random() * 900000));
      const purpose = String(body.purpose ?? "confirm").slice(0, 40);
      await supabase.from("nx_otp").insert({
        user_id: user.id, code_hash: await sha256(code), purpose,
      });
      const email = user.email ?? "";
      const result = await sendViaResend(
        email,
        `Your NexCore verification code: ${code}`,
        `<div style="font-family:sans-serif"><h2>NexCore verification</h2><p>Your one-time code is:</p><p style="font-size:32px;font-weight:800;letter-spacing:8px">${code}</p><p>It expires in 5 minutes. If you didn't request this, ignore this email.</p></div>`,
      );
      await supabase.from("nx_email_log").insert({
        sent_by: user.id, recipient: email, subject: "OTP verification code",
        provider: result.simulated ? "simulated" : "resend",
        provider_id: result.id, status: result.simulated ? "simulated" : "sent",
      });
      // In simulated mode (no RESEND_API_KEY) return the code so the demo flow still works.
      return json({ ok: true, simulated: result.simulated, demo_code: result.simulated ? code : undefined });
    }

    if (action === "verify_otp") {
      const code = String(body.code ?? "").trim();
      if (!/^\d{6}$/.test(code)) return json({ ok: false, error: "bad_code" }, 400);
      const hash = await sha256(code);
      const { data: rows } = await supabase.from("nx_otp")
        .select("id, expires_at, used_at")
        .eq("user_id", user.id).eq("code_hash", hash)
        .order("created_at", { ascending: false }).limit(1);
      const row = rows?.[0];
      if (!row || row.used_at || new Date(row.expires_at) < new Date()) {
        return json({ ok: false, error: "invalid_or_expired" }, 400);
      }
      await supabase.from("nx_otp").update({ used_at: new Date().toISOString() }).eq("id", row.id);
      return json({ ok: true });
    }

    return json({ error: "unknown_action" }, 400);
  } catch (e) {
    return json({ error: String(e).slice(0, 300) }, 500);
  }
});
