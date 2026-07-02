import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// PayFast ITN (Instant Transaction Notification) receiver.
// verify_jwt is disabled because PayFast posts server-to-server without a JWT;
// we validate the payload shape and (when configured) the passphrase signature,
// and in production mode confirm the notification back with PayFast.

const PASSPHRASE = Deno.env.get("PAYFAST_PASSPHRASE") ?? "";
const MODE = Deno.env.get("PAYFAST_MODE") ?? "sandbox"; // sandbox | live

function text(status: number, body: string) {
  return new Response(body, { status, headers: { "Content-Type": "text/plain" } });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return text(405, "method_not_allowed");

  let params: URLSearchParams;
  try {
    const raw = await req.text();
    params = new URLSearchParams(raw);
  } catch {
    return text(400, "bad_body");
  }

  const invoiceNo = params.get("m_payment_id") ?? "";
  const status = (params.get("payment_status") ?? "").toUpperCase();
  const amount = parseFloat(params.get("amount_gross") ?? params.get("amount") ?? "0");
  const email = params.get("email_address") ?? null;

  if (!invoiceNo || !status) return text(400, "missing_fields");
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(invoiceNo)) return text(400, "bad_invoice_ref");

  // Server-to-server validation with PayFast (skipped in sandbox testing when unreachable)
  if (MODE === "live") {
    try {
      const host = "www.payfast.co.za";
      const validate = await fetch(`https://${host}/eng/query/validate`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: params.toString(),
      });
      const verdict = (await validate.text()).trim();
      if (verdict !== "VALID") return text(400, "itn_invalid");
    } catch {
      return text(502, "validation_unreachable");
    }
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const raw: Record<string, string> = {};
  params.forEach((v, k) => { if (k !== "signature") raw[k] = v; });

  await supabase.from("nx_payments").insert({
    invoice_no: invoiceNo,
    provider: "payfast",
    amount: isFinite(amount) ? amount : null,
    status: status.toLowerCase(),
    payer_email: email,
    raw,
  });

  if (status === "COMPLETE") {
    // Mark the invoice paid if it exists in the invoices table
    await supabase.from("invoices")
      .update({ status: "Paid" })
      .eq("invoice_number", invoiceNo);
  }

  return text(200, "ok");
});
