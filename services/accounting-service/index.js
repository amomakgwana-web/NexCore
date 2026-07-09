// Hero service: real business logic, not just CRUD.
// Enforces the one rule that actually matters for a GL: a journal entry's
// debits must equal its credits. There is no separate chart-of-accounts
// table in this schema (COA lives client-side in the frontend today), so
// the trial balance here is computed by replaying every posted journal's
// lines and summing by account code — a real aggregation over real rows,
// not a hardcoded table.
const path = require('path');
const { createService, mountCrud, getSupabaseClient, start } = require(path.join(__dirname, '../_shared/serviceFactory'));

const { app } = createService('accounting-service');
const supabase = getSupabaseClient();

mountCrud(app, { table: 'budget_lines', resource: 'budget-lines', supabase });
// journals are exposed read-only via CRUD (GET) below; POST goes through
// /journals/post so every entry passes balance validation.
app.get('/journals', async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 100, 500);
  const { data, error } = await supabase.from('nx_journals').select('*').order('jdate', { ascending: false }).limit(limit);
  if (error) return res.status(500).json({ error: error.message });
  res.json({ data, count: data.length });
});
app.get('/journals/:id', async (req, res) => {
  const { data, error } = await supabase.from('nx_journals').select('*').eq('id', req.params.id).maybeSingle();
  if (error) return res.status(500).json({ error: error.message });
  if (!data) return res.status(404).json({ error: 'journal not found' });
  res.json({ data });
});

app.post('/journals/post', async (req, res) => {
  const { ref, date, narration, lines, postedBy } = req.body || {};
  if (!Array.isArray(lines) || lines.length < 2) {
    return res.status(400).json({ error: 'lines must be an array of at least 2 {acct, debit, credit} entries' });
  }
  const totalDebit = lines.reduce((s, l) => s + Number(l.debit || 0), 0);
  const totalCredit = lines.reduce((s, l) => s + Number(l.credit || 0), 0);
  if (Math.round((totalDebit - totalCredit) * 100) !== 0) {
    return res.status(400).json({ error: 'unbalanced_entry', totalDebit, totalCredit, message: `Debits (${totalDebit}) must equal credits (${totalCredit})` });
  }
  const { data, error } = await supabase.from('nx_journals').insert({
    ref: ref || ('JNL-' + Date.now()), jdate: date || new Date().toISOString().slice(0, 10),
    narration: narration || '', lines, posted_by: postedBy || null,
  }).select().single();
  if (error) return res.status(400).json({ error: error.message });
  res.status(201).json({ data });
});

app.get('/trial-balance', async (req, res) => {
  const { data: journals, error } = await supabase.from('nx_journals').select('lines');
  if (error) return res.status(500).json({ error: error.message });
  const byAccount = {};
  for (const j of journals || []) {
    for (const l of j.lines || []) {
      if (!byAccount[l.acct]) byAccount[l.acct] = { debit: 0, credit: 0 };
      byAccount[l.acct].debit += Number(l.debit || 0);
      byAccount[l.acct].credit += Number(l.credit || 0);
    }
  }
  const totalDebit = Object.values(byAccount).reduce((s, a) => s + a.debit, 0);
  const totalCredit = Object.values(byAccount).reduce((s, a) => s + a.credit, 0);
  res.json({ data: { byAccount, totalDebit, totalCredit, balanced: Math.round((totalDebit - totalCredit) * 100) === 0 } });
});

start(app, 'accounting-service');
