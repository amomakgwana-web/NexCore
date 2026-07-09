// Hero service: real business logic, not just CRUD.
// VAT calc + a genuine recurring-billing engine (ported from the same
// approach used in nexcore-standalone.html's invCheckRecurringDue). Recurring
// schedules are persisted in nx_module_state (module='billing-recurring'),
// NOT in-process memory — with multiple replicas behind a load balancer, any
// replica must see the same schedule, so process-local state would silently
// break the moment a second request landed on a different instance.
const path = require('path');
const { createService, mountCrud, getSupabaseClient, start } = require(path.join(__dirname, '../_shared/serviceFactory'));

const { app } = createService('billing-service');
const supabase = getSupabaseClient();

const RECUR_MODULE = 'billing-recurring';

async function loadRecurringConfig() {
  const { data, error } = await supabase.from('nx_module_state').select('state').eq('module', RECUR_MODULE).maybeSingle();
  if (error) throw new Error(error.message);
  return data?.state || {};
}
async function saveRecurringConfig(cfg) {
  const { error } = await supabase.from('nx_module_state').upsert({ module: RECUR_MODULE, state: cfg, updated_at: new Date().toISOString() });
  if (error) throw new Error(error.message);
}
function advanceDate(dateStr, frequency) {
  const d = new Date(dateStr + 'T00:00:00Z');
  if (frequency === 'Quarterly') d.setUTCMonth(d.getUTCMonth() + 3);
  else if (frequency === 'Annually') d.setUTCFullYear(d.getUTCFullYear() + 1);
  else d.setUTCMonth(d.getUTCMonth() + 1);
  return d.toISOString().slice(0, 10);
}

mountCrud(app, { table: 'invoices', resource: 'invoices', supabase, defaultOrder: 'created_at' });

app.post('/invoices/create', async (req, res) => {
  const { clientName, contactEmail, amountExcl, dueDate, description, reference } = req.body || {};
  if (!clientName || !amountExcl) return res.status(400).json({ error: 'clientName and amountExcl are required' });
  const vatAmount = Math.round(amountExcl * 0.15 * 100) / 100;
  const invoiceNumber = 'INV-' + Date.now().toString().slice(-6);
  const { data, error } = await supabase.from('invoices').insert({
    invoice_number: invoiceNumber, client_name: clientName, contact_email: contactEmail || null,
    amount_excl: amountExcl, vat_amount: vatAmount, total_amount: amountExcl + vatAmount,
    status: 'Draft', issue_date: new Date().toISOString().slice(0, 10), due_date: dueDate || null,
    description: description || null, reference: reference || null,
  }).select().single();
  if (error) return res.status(400).json({ error: error.message });
  res.status(201).json({ data });
});

app.post('/invoices/:id/recurring', async (req, res) => {
  const { frequency } = req.body || {}; // 'Monthly' | 'Quarterly' | 'Annually' | null to disable
  const { data: inv, error: invErr } = await supabase.from('invoices').select('*').eq('id', req.params.id).maybeSingle();
  if (invErr) return res.status(500).json({ error: invErr.message });
  if (!inv) return res.status(404).json({ error: 'invoice not found' });
  const cfg = await loadRecurringConfig();
  if (!frequency) { delete cfg[req.params.id]; }
  else { cfg[req.params.id] = { frequency, nextDate: advanceDate(inv.issue_date || new Date().toISOString().slice(0, 10), frequency) }; }
  await saveRecurringConfig(cfg);
  res.json({ data: cfg[req.params.id] || null });
});

// Actually generates the follow-on invoice(s) for any schedule whose next
// date has passed — a real state transition, not a status flag.
app.post('/recurring/run-due', async (req, res) => {
  const today = new Date().toISOString().slice(0, 10);
  const cfg = await loadRecurringConfig();
  const generated = [];
  for (const [invoiceId, sched] of Object.entries(cfg)) {
    let guard = 0;
    while (sched.nextDate <= today && guard < 24) {
      guard++;
      const { data: parent } = await supabase.from('invoices').select('*').eq('id', invoiceId).maybeSingle();
      if (!parent) break;
      const invoiceNumber = 'INV-' + Date.now().toString().slice(-6) + '-' + guard;
      const { data: created, error } = await supabase.from('invoices').insert({
        invoice_number: invoiceNumber, client_name: parent.client_name, contact_email: parent.contact_email,
        amount_excl: parent.amount_excl, vat_amount: parent.vat_amount, total_amount: parent.total_amount,
        status: 'Draft', issue_date: today, due_date: advanceDate(today, sched.frequency),
        description: parent.description, reference: parent.reference,
      }).select().single();
      if (!error && created) generated.push(created);
      sched.nextDate = advanceDate(sched.nextDate, sched.frequency);
    }
  }
  await saveRecurringConfig(cfg);
  res.json({ generatedCount: generated.length, generated });
});

app.get('/aging', async (req, res) => {
  const { data: invoices, error } = await supabase.from('invoices').select('*').neq('status', 'Paid');
  if (error) return res.status(500).json({ error: error.message });
  const today = new Date();
  const buckets = { current: 0, days30: 0, days60: 0, days90: 0, days120plus: 0 };
  for (const inv of invoices || []) {
    if (!inv.due_date) continue;
    const days = Math.floor((today - new Date(inv.due_date)) / 86400000);
    const amt = Number(inv.total_amount) || 0;
    if (days <= 0) buckets.current += amt;
    else if (days <= 30) buckets.days30 += amt;
    else if (days <= 60) buckets.days60 += amt;
    else if (days <= 90) buckets.days90 += amt;
    else buckets.days120plus += amt;
  }
  res.json({ data: buckets, openInvoiceCount: (invoices || []).length });
});

start(app, 'billing-service');
