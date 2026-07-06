import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// One-shot idempotent bootstrap: creates the six workspace accounts as REAL
// Supabase auth users (passwords match the in-app demo credentials, which are
// already public in the client source — this adds no new exposure, it upgrades
// those logins to real sessions so RLS and persistence apply).

const USERS = [
  { email: "amohelang@xgroup.co.za", password: "admin2025",  role: "admin",      name: "Amohelang M.",  initials: "AM", color: "#F97316" },
  { email: "cfo@xgroup.co.za",       password: "cfo2025",    role: "cfo",        name: "Amohelang M.",  initials: "AM", color: "#F59E0B" },
  { email: "thabo@xgroup.co.za",     password: "manager2025",role: "manager",    name: "Thabo Mokoena", initials: "TM", color: "#3B82F6" },
  { email: "lerato@xgroup.co.za",    password: "hr2025",     role: "hr_manager", name: "Lerato Khumalo",initials: "LK", color: "#16A34A" },
  { email: "kagiso@xgroup.co.za",    password: "staff2025",  role: "staff",      name: "Kagiso Dlamini",initials: "KD", color: "#0891B2" },
  { email: "accounts@dell.co.za",    password: "vendor2025", role: "vendor",     name: "Dell Tech SA",  initials: "DT", color: "#1D4ED8" },
];

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("method_not_allowed", { status: 405 });
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const results: Record<string, string> = {};
  for (const u of USERS) {
    try {
      const { data: created, error } = await admin.auth.admin.createUser({
        email: u.email, password: u.password, email_confirm: true,
      });
      let uid = created?.user?.id;
      if (error) {
        if (!String(error.message).toLowerCase().includes("already")) {
          results[u.email] = "error: " + error.message; continue;
        }
        const { data: list } = await admin.auth.admin.listUsers({ perPage: 200 });
        uid = list?.users?.find((x) => x.email === u.email)?.id;
        results[u.email] = "exists";
      } else {
        results[u.email] = "created";
      }
      if (uid) {
        await admin.from("user_profiles").upsert({
          id: uid, role: u.role, full_name: u.name,
          initials: u.initials, avatar_color: u.color, org: "xGroup SA",
        }, { onConflict: "id" });
      }
    } catch (e) {
      results[u.email] = "error: " + String(e).slice(0, 120);
    }
  }
  return new Response(JSON.stringify({ ok: true, results }), {
    headers: { "Content-Type": "application/json" },
  });
});
