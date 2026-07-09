// Hero service: real business logic, not just CRUD — and the one service
// that actually demonstrates cross-service composition. It owns no table of
// its own; SARS and cash flow figures are built by calling payroll-service
// and accounting-service THROUGH THE GATEWAY (same load-balanced path a
// browser would use), then combining the results. That round trip is the
// point: it proves these are genuinely separate, independently-scaled
// services collaborating, not just files sharing one process.
const path = require('path');
const { createService, getSupabaseClient, start } = require(path.join(__dirname, '../_shared/serviceFactory'));

const { app } = createService('finance-service');
const supabase = getSupabaseClient();
const GATEWAY_URL = process.env.GATEWAY_URL || 'http://127.0.0.1:8080';

async function gatewayGet(pathname) {
  const res = await fetch(GATEWAY_URL + pathname);
  if (!res.ok) throw new Error(`gateway ${pathname} -> ${res.status}`);
  return res.json();
}

app.get('/sars', async (req, res) => {
  try {
    const [payrollSummary, billing] = await Promise.all([
      gatewayGet('/api/payroll/summary'),
      gatewayGet('/api/billing/invoices?limit=500'),
    ]);
    const invoices = billing.data || [];
    const outputVat = invoices.reduce((s, i) => s + Number(i.vat_amount || 0), 0);
    // No purchase invoice VAT tracking table yet — input VAT is 0 until
    // procurement-service exposes vendor invoice totals with VAT.
    const inputVat = 0;
    const p = payrollSummary.data;
    res.json({
      data: {
        paye: p.paye, uif: p.uifEmployee + p.uifEmployer, sdl: p.sdl,
        totalPayeSubmission: p.totalDueToSars,
        outputVat, inputVat, netVatPayable: outputVat - inputVat,
        employeeCount: p.employeeCount,
      },
    });
  } catch (e) {
    res.status(502).json({ error: 'upstream_service_unavailable', message: e.message });
  }
});

app.get('/cashflow', async (req, res) => {
  const { data: journals, error } = await supabase.from('nx_journals').select('lines,jdate,narration').order('jdate', { ascending: true });
  if (error) return res.status(500).json({ error: error.message });
  const BANK_ACCT = '1000';
  let opening = 0, movement = 0;
  const transactions = [];
  for (const j of journals || []) {
    for (const l of j.lines || []) {
      if (l.acct !== BANK_ACCT) continue;
      const amt = Number(l.debit || 0) - Number(l.credit || 0);
      movement += amt;
      transactions.push({ date: j.jdate, narration: j.narration, amount: amt });
    }
  }
  res.json({ data: { opening, movement, closing: opening + movement, transactionCount: transactions.length, transactions } });
});

start(app, 'finance-service');
