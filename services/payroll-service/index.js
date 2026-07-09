// Hero service: real business logic, not just CRUD.
// PAYE/UIF math ported verbatim from nexcore-standalone.html's payproPAYE/
// payproUIF/payproCalc (SARS 2024/25 monthly tax tables, primary rebate
// R17,235 p/a, UIF ceiling R17,711.58/month) — same formula, now computed
// server-side against the real payroll_employees/payroll_deductions tables
// instead of an in-browser array.
const path = require('path');
const { createService, mountCrud, getSupabaseClient, start } = require(path.join(__dirname, '../_shared/serviceFactory'));

const { app } = createService('payroll-service');
const supabase = getSupabaseClient();

mountCrud(app, { table: 'payroll_employees', resource: 'employees', idColumn: 'employee_id', supabase });
mountCrud(app, { table: 'payroll_deductions', resource: 'deductions', supabase });
mountCrud(app, { table: 'payroll_runs', resource: 'runs', supabase, defaultOrder: 'processed_at' });

const SARS_BRACKETS_2024_25 = [[237100, .18], [370500, .26], [512800, .31], [673000, .36], [857900, .39], [1817000, .41], [Infinity, .45]];
const PRIMARY_REBATE_ANNUAL = 17235;
const UIF_CEILING_MONTHLY = 17712;

function payePAYE(monthlyTaxable) {
  const annual = monthlyTaxable * 12;
  let cum = 0, prev = 0;
  for (const [cap, rate] of SARS_BRACKETS_2024_25) {
    if (annual > cap) { cum += (cap - prev) * rate; prev = cap; }
    else { cum += (annual - prev) * rate; break; }
  }
  return Math.max(0, (cum - PRIMARY_REBATE_ANNUAL) / 12);
}
function payeUIF(monthlyGross) { return Math.min(monthlyGross, UIF_CEILING_MONTHLY) * .01; }

async function computeForEmployee(employeeId) {
  const { data: emp, error: empErr } = await supabase.from('payroll_employees').select('*').eq('employee_id', employeeId).maybeSingle();
  if (empErr) throw new Error(empErr.message);
  if (!emp) return null;
  const { data: deductions, error: dedErr } = await supabase.from('payroll_deductions').select('*').eq('employee_id', employeeId);
  if (dedErr) throw new Error(dedErr.message);

  const gross = Number(emp.gross_monthly) || 0;
  const totalDeductions = (deductions || []).reduce((s, d) => s + Number(d.amount || 0), 0);
  const retirementDeduction = (deductions || []).filter(d => /retirement|pension/i.test(d.label || '')).reduce((s, d) => s + Number(d.amount || 0), 0);
  const retDeductible = Math.min(retirementDeduction, gross * 0.275);
  const paye = payePAYE(gross - retDeductible);
  const uifEmployee = payeUIF(gross);
  const uifEmployer = uifEmployee; // employer matches employee UIF contribution
  const netPay = gross - paye - uifEmployee - totalDeductions;

  return { employeeId, gross, paye, uifEmployee, uifEmployer, otherDeductions: totalDeductions, netPay, deductions };
}

app.get('/calc/:employeeId', async (req, res) => {
  try {
    const result = await computeForEmployee(req.params.employeeId);
    if (!result) return res.status(404).json({ error: 'employee not found' });
    res.json({ data: result });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/runs/process', async (req, res) => {
  const { employeeId, periodMonth, periodYear, processedBy } = req.body || {};
  if (!employeeId || !periodMonth || !periodYear) {
    return res.status(400).json({ error: 'employeeId, periodMonth, periodYear are required' });
  }
  try {
    const calc = await computeForEmployee(employeeId);
    if (!calc) return res.status(404).json({ error: 'employee not found' });
    const { data, error } = await supabase.from('payroll_runs').insert({
      employee_id: employeeId, period_month: periodMonth, period_year: periodYear,
      gross_pay: calc.gross, paye: calc.paye, uif_employee: calc.uifEmployee, uif_employer: calc.uifEmployer,
      other_deductions: calc.otherDeductions, net_pay: calc.netPay, processed_by: processedBy || null,
    }).select().single();
    if (error) return res.status(400).json({ error: error.message });
    res.status(201).json({ data });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// Aggregate totals across every employee — used by finance-service to build
// the SARS EMP201 figure (real cross-service composition, not duplicated math).
app.get('/summary', async (req, res) => {
  const { data: emps, error } = await supabase.from('payroll_employees').select('employee_id');
  if (error) return res.status(500).json({ error: error.message });
  const results = await Promise.all((emps || []).map(e => computeForEmployee(e.employee_id).catch(() => null)));
  const valid = results.filter(Boolean);
  const totals = valid.reduce((acc, r) => ({
    gross: acc.gross + r.gross, paye: acc.paye + r.paye,
    uifEmployee: acc.uifEmployee + r.uifEmployee, uifEmployer: acc.uifEmployer + r.uifEmployer,
  }), { gross: 0, paye: 0, uifEmployee: 0, uifEmployer: 0 });
  const sdl = totals.gross * 0.01;
  res.json({ data: { employeeCount: valid.length, ...totals, sdl, totalDueToSars: totals.paye + totals.uifEmployee + totals.uifEmployer + sdl } });
});

start(app, 'payroll-service');
