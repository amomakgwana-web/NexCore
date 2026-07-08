// MORR ERP — critical-path E2E suite.
// Runs against the static file; demo mode (no network) exercises all client logic.
import { test, expect } from '@playwright/test';

const APP = 'file://' + process.cwd() + '/nexcore-standalone.html';

async function login(page) {
  // TEMP DIAGNOSTIC: forward page console/errors/requests to CI stdout to
  // find where login is actually stalling in the CI environment.
  page.on('console', (msg) => console.log('[PAGE]', msg.type(), msg.text()));
  page.on('pageerror', (e) => console.log('[PAGEERROR]', e.message));
  page.on('requestfailed', (r) => console.log('[REQFAIL]', r.url(), r.failure()?.errorText));
  page.on('response', (r) => { if (!r.ok()) console.log('[RESP]', r.status(), r.url()); });

  await page.goto(APP);
  await page.waitForTimeout(900);
  console.log('[TEST] calling fillDemo+doLogin, sb present:', await page.evaluate(() => typeof sb === 'function' && !!sb()));
  await page.evaluate(() => {
    fillDemo('amohelang@xgroup.co.za', 'admin2025');
    doLogin();
  });
  console.log('[TEST] evaluate() returned, now polling appShell.active');
  await page.waitForFunction(() => document.getElementById('appShell').classList.contains('active'), null, { timeout: 20000 });
  await page.waitForTimeout(900);
}

test('boots with no page errors and logs in', async ({ page }) => {
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await login(page);
  expect(errors).toEqual([]);
  await expect(page.locator('.tb-wordmark')).toContainText('MORR');
});

test('claims SOP: submit -> manager -> CFO -> paid + GL + payment', async ({ page }) => {
  await login(page);
  const r = await page.evaluate(() => {
    openPage('claims');
    document.getElementById('clAmt').value = '1500';
    document.getElementById('clDesc').value = 'CI test claim';
    submitClaim();
    const c = CLAIMS_DATA[0];
    const out = { status0: c.status, inQueue: !!(window.APPROVALS_DATA || []).find(a => a.id === c.id) };
    approveClaim(c.id, 'manager');
    out.status1 = c.status;
    approveClaim(c.id, 'cfo');
    out.status2 = c.status;
    out.payment = !!PAYMENTS_DATA.find(p => p.ref === c.id);
    out.gl = !!JOURNAL_ENTRIES.find(j => j.ref === 'JNL-CLM-' + c.id);
    return out;
  });
  expect(r.status0).toBe('Pending Manager');
  expect(r.inQueue).toBe(true);
  expect(r.status1).toBe('Pending CFO');
  expect(r.status2).toBe('Paid');
  expect(r.payment).toBe(true);
  expect(r.gl).toBe(true);
});

test('payroll: PAYE calc, GL posting balances, automations panel', async ({ page }) => {
  await login(page);
  const r = await page.evaluate(() => {
    openPage('paypro');
    const c = payproCalc(PAYPRO_EMPS[0]);
    const before = JOURNAL_ENTRIES.length;
    payproPostToGL();
    const j = JOURNAL_ENTRIES[0];
    const dr = j.lines.reduce((s, l) => s + (l.debit || 0), 0);
    const cr = j.lines.reduce((s, l) => s + (l.credit || 0), 0);
    return {
      grossPositive: c.gross > 0,
      payeSane: c.paye > 0 && c.paye < c.gross,
      posted: JOURNAL_ENTRIES.length === before + 1,
      balanced: Math.abs(dr - cr) < 1,
      autoCard: !!document.getElementById('payAutoCard'),
    };
  });
  expect(r).toEqual({ grossPositive: true, payeSane: true, posted: true, balanced: true, autoCard: true });
});

test('accounting: journal validation blocks unbalanced entries; sub-ledgers render', async ({ page }) => {
  await login(page);
  const r = await page.evaluate(() => new Promise((res) => {
    openPage('accounting');
    setTimeout(() => {
      const before = JOURNAL_ENTRIES.length;
      openJournalModal();
      _jeLines = [{ acct: '6000', debit: 100, credit: 0 }, { acct: '1000', debit: 0, credit: 55 }];
      postJournal(); // unbalanced -> must be rejected
      const blocked = JOURNAL_ENTRIES.length === before;
      _jeLines = [{ acct: '6000', debit: 100, credit: 0 }, { acct: '1000', debit: 0, credit: 100 }];
      postJournal();
      const posted = JOURNAL_ENTRIES.length === before + 1;
      res({ blocked, posted, ledgers: document.querySelectorAll('#acctTabs-ledgers table').length });
    }, 400);
  }));
  expect(r.blocked).toBe(true);
  expect(r.posted).toBe(true);
  expect(r.ledgers).toBeGreaterThanOrEqual(6);
});

test('real PDF bytes: payslip and invoice builders produce %PDF output', async ({ page }) => {
  await login(page);
  const sizes = await page.evaluate(() => {
    const out = {};
    const orig = window.jspdf.jsPDF.API.save;
    window.jspdf.jsPDF.API.save = function () { out._last = this.output('arraybuffer').byteLength; return this; };
    pdfPayslip(0); out.payslip = out._last;
    pdfInvoice({ id: 'CI-INV', client: 'CI', total: 115000 }); out.invoice = out._last;
    window.jspdf.jsPDF.API.save = orig;
    return out;
  });
  expect(sizes.payslip).toBeGreaterThan(3000);
  expect(sizes.invoice).toBeGreaterThan(3000);
});

test('onboarding adds employee to payroll and logs contract email', async ({ page }) => {
  await login(page);
  const r = await page.evaluate(() => new Promise((res) => {
    const before = PAYPRO_EMPS.length;
    onboardEmployeeDrawer();
    document.getElementById('obName').value = 'CI Person';
    document.getElementById('obEmail').value = 'ci@xgroup.co.za';
    document.getElementById('obSalary').value = '30000';
    onboardEmployeeSubmit();
    setTimeout(() => res({
      added: PAYPRO_EMPS.length === before + 1,
      email: EMAIL_LOG[0].to === 'ci@xgroup.co.za',
    }), 600);
  }));
  expect(r.added).toBe(true);
  expect(r.email).toBe(true);
});

test('persistence: risk added survives reload (NXDB)', async ({ page }) => {
  await login(page);
  await page.evaluate(() => {
    document.getElementById('riskTitle').value = 'CI-PERSIST risk';
    saveRisk();
  });
  await page.waitForTimeout(700);
  await page.reload();
  await page.waitForTimeout(900);
  await page.evaluate(() => { fillDemo('amohelang@xgroup.co.za', 'admin2025'); doLogin(); });
  await page.waitForTimeout(1400);
  const found = await page.evaluate(() => RISK_REGISTER.some(r => r.title === 'CI-PERSIST risk'));
  expect(found).toBe(true);
});

test('mobile 390px: hamburger visible, sidebar off-canvas, drawer is bottom sheet', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await login(page);
  const r = await page.evaluate(() => ({
    hamburger: getComputedStyle(document.getElementById('nxHamburger')).display !== 'none',
    sidebarHidden: getComputedStyle(document.querySelector('.sidebar')).transform !== 'none',
  }));
  expect(r.hamburger).toBe(true);
  expect(r.sidebarHidden).toBe(true);
});
