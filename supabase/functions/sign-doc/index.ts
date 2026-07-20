import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Public e-signature endpoint. verify_jwt=false: the unguessable token IS the
// credential (128-bit, single-document scope, 14-day expiry, single use).
// GET  ?token=... -> mobile-friendly signing page with the document + pad
//                    (doc_type='onboarding_details' renders a personal
//                    details + NDA form instead of a signature pad)
// POST {token, signature} -> stores signature, marks signed
// POST {token, personalDetails} -> stores personal details + NDA ack, marks signed

function admin() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
}

const PAGE = (title: string, inner: string) => `<!DOCTYPE html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title><style>
body{font-family:system-ui,sans-serif;margin:0;background:#f4f4f5;color:#18181b;}
.wrap{max-width:760px;margin:0 auto;padding:16px;}
.doc{background:#fff;border-radius:14px;padding:20px;box-shadow:0 4px 16px rgba(0,0,0,.08);overflow-x:auto;}
.bar{background:#18181b;color:#fff;padding:14px 18px;font-weight:700;display:flex;justify-content:space-between;align-items:center;position:sticky;top:0;}
.pad{background:#fff;border-radius:14px;padding:16px;margin-top:14px;box-shadow:0 4px 16px rgba(0,0,0,.08);}
canvas{border:2px dashed #d4d4d8;border-radius:10px;width:100%;height:160px;touch-action:none;background:#fafafa;}
button{font:inherit;font-weight:700;border:none;border-radius:10px;padding:12px 20px;cursor:pointer;}
.sign{background:#F97316;color:#fff;width:100%;margin-top:10px;font-size:16px;}
.clear{background:#e4e4e7;color:#3f3f46;margin-top:8px;}
.ok{max-width:480px;margin:12vh auto;text-align:center;background:#fff;border-radius:16px;padding:40px 24px;box-shadow:0 8px 32px rgba(0,0,0,.1);}
label{display:block;font-size:12px;font-weight:700;color:#52525b;margin:14px 0 4px;}
input[type=text],textarea{width:100%;box-sizing:border-box;padding:10px 12px;border:1px solid #d4d4d8;border-radius:8px;font:inherit;font-size:14px;}
.nda-box{max-height:180px;overflow-y:auto;border:1px solid #e4e4e7;border-radius:8px;padding:12px;font-size:12px;color:#3f3f46;background:#fafafa;margin-top:6px;}
.chk{display:flex;align-items:flex-start;gap:8px;margin-top:12px;font-size:12px;color:#3f3f46;}
.chk input{margin-top:3px;}
</style></head><body>${inner}</body></html>`;

const NDA_TEXT = `Confidentiality & Non-Disclosure: I acknowledge that in the course of my
engagement I will have access to confidential business, client, financial and
personal information. I agree not to disclose or use such information for any
purpose outside the proper performance of my role, both during and after my
engagement, in accordance with company policy and the Protection of Personal
Information Act (POPIA).`;

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);

  if (req.method === "GET") {
    const token = url.searchParams.get("token") ?? "";
    if (!/^[a-f0-9]{24,64}$/.test(token)) return new Response("invalid link", { status: 400 });
    const { data: rows } = await admin().from("nx_sign_requests")
      .select("doc_type, doc_title, doc_html, party_name, status, expires_at").eq("token", token).limit(1);
    const r = rows?.[0];
    if (!r) return new Response(PAGE("Not found", `<div class="ok"><h2>Link not found</h2><p>This signing link is invalid.</p></div>`), { headers: { "Content-Type": "text/html" }, status: 404 });
    if (r.status === "signed") return new Response(PAGE("Already signed", `<div class="ok"><h2>✓ Already signed</h2><p>${r.doc_title} was signed. Both parties have a copy.</p></div>`), { headers: { "Content-Type": "text/html" } });
    if (new Date(r.expires_at) < new Date()) return new Response(PAGE("Expired", `<div class="ok"><h2>Link expired</h2><p>Ask the sender to issue a new signing request.</p></div>`), { headers: { "Content-Type": "text/html" } });
    await admin().from("nx_sign_requests").update({ status: "viewed" }).eq("token", token).eq("status", "sent");

    if (r.doc_type === "onboarding_details") {
      const inner = `
<div class="bar"><span>📋 ${r.doc_title}</span><span style="font-size:12px;font-weight:400;">for ${r.party_name}</span></div>
<div class="wrap">
  <div class="doc">
    <p style="font-size:13px;color:#52525b;">Please confirm your personal details and accept the confidentiality agreement below to complete your onboarding.</p>
    <label>Full Legal Name</label><input type="text" id="fName" value="${r.party_name}"/>
    <label>ID / Passport Number</label><input type="text" id="fId" placeholder="e.g. 9001015800088"/>
    <label>Physical Address</label><textarea id="fAddr" rows="3" placeholder="Street, suburb, city, postal code"></textarea>
    <label>Non-Disclosure Agreement</label>
    <div class="nda-box">${NDA_TEXT}</div>
    <div class="chk"><input type="checkbox" id="fNda"/><span>I have read and agree to the confidentiality and non-disclosure terms above.</span></div>
  </div>
  <div class="pad">
    <button class="sign" onclick="submitDetails()">Submit Details</button>
    <p style="font-size:11px;color:#71717a;">Your IP and a timestamp are recorded when you submit.</p>
  </div>
</div>
<script>
async function submitDetails(){
  const idNumber=document.getElementById('fId').value.trim();
  const address=document.getElementById('fAddr').value.trim();
  const ndaAccepted=document.getElementById('fNda').checked;
  if(!idNumber||!address){alert('Please complete your ID number and address');return;}
  if(!ndaAccepted){alert('Please accept the confidentiality agreement to continue');return;}
  const res=await fetch(location.pathname,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({token:new URLSearchParams(location.search).get('token'),personalDetails:{fullName:document.getElementById('fName').value.trim(),idNumber,address,ndaAccepted}})});
  if(res.ok){document.body.innerHTML='<div class="ok"><h2 style="color:#16A34A">✓ Details submitted</h2><p>Thank you — your onboarding details have been recorded.</p></div>';}
  else{alert('Submission failed — try again');}
}
</script>`;
      return new Response(PAGE(r.doc_title, inner), { headers: { "Content-Type": "text/html" } });
    }

    const inner = `
<div class="bar"><span>✍ ${r.doc_title}</span><span style="font-size:12px;font-weight:400;">for ${r.party_name}</span></div>
<div class="wrap">
  <div class="doc">${r.doc_html}</div>
  <div class="pad">
    <b>Sign here</b> — draw with your finger, stylus or mouse
    <canvas id="c"></canvas>
    <button class="sign" onclick="submitSig()">Sign Document</button>
    <button class="clear" onclick="clearSig()">Clear</button>
    <p style="font-size:11px;color:#71717a;">By signing you agree this electronic signature is legally binding under ECTA (Act 25 of 2002). Your IP and a timestamp are recorded.</p>
  </div>
</div>
<script>
const c=document.getElementById('c');
c.width=c.offsetWidth*2;c.height=320;
const x=c.getContext('2d');x.scale(2,2);x.strokeStyle='#111';x.lineWidth=2.5;x.lineCap='round';
let d=false,drawn=false;
const pos=e=>{const r=c.getBoundingClientRect();return[(e.clientX-r.left),(e.clientY-r.top)];};
c.addEventListener('pointerdown',e=>{e.preventDefault();c.setPointerCapture(e.pointerId);d=true;drawn=true;x.beginPath();x.moveTo(...pos(e));});
c.addEventListener('pointermove',e=>{if(!d)return;e.preventDefault();x.lineTo(...pos(e));x.stroke();});
c.addEventListener('pointerup',()=>d=false);
function clearSig(){x.clearRect(0,0,c.width,c.height);drawn=false;}
async function submitSig(){
  if(!drawn){alert('Draw your signature first');return;}
  const res=await fetch(location.pathname,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({token:new URLSearchParams(location.search).get('token'),signature:c.toDataURL('image/png')})});
  if(res.ok){document.body.innerHTML='<div class=\\"ok\\"><h2 style=\\"color:#16A34A\\">✓ Signed successfully</h2><p>Thank you. Both parties receive a sealed copy.</p></div>';}
  else{alert('Signing failed — try again');}
}
</script>`;
    return new Response(PAGE(r.doc_title, inner), { headers: { "Content-Type": "text/html" } });
  }

  if (req.method === "POST") {
    let body: Record<string, unknown>;
    try { body = await req.json(); } catch { return new Response("bad_json", { status: 400 }); }
    const token = String(body.token ?? "");
    if (!/^[a-f0-9]{24,64}$/.test(token)) return new Response("bad_token", { status: 400 });
    const { data: rows } = await admin().from("nx_sign_requests")
      .select("id, status, expires_at, doc_title, party_name").eq("token", token).limit(1);
    const r = rows?.[0];
    if (!r || r.status === "signed" || new Date(r.expires_at) < new Date()) {
      return new Response("unavailable", { status: 410 });
    }
    const ip = req.headers.get("x-forwarded-for")?.split(",")[0] ?? null;

    if (body.personalDetails && typeof body.personalDetails === "object") {
      const pd = body.personalDetails as Record<string, unknown>;
      if (!pd.idNumber || !pd.address || !pd.ndaAccepted) return new Response("incomplete_details", { status: 400 });
      await admin().from("nx_sign_requests").update({
        status: "signed", personal_details: pd, signed_at: new Date().toISOString(), signer_ip: ip,
      }).eq("id", r.id);
      return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
    }

    const signature = String(body.signature ?? "");
    if (!signature.startsWith("data:image/png;base64,") || signature.length > 200_000) {
      return new Response("bad_signature", { status: 400 });
    }
    await admin().from("nx_sign_requests").update({
      status: "signed", signature, signed_at: new Date().toISOString(), signer_ip: ip,
    }).eq("id", r.id);
    return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
  }

  return new Response("method_not_allowed", { status: 405 });
});
