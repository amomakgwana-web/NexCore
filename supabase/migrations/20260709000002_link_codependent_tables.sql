-- Link co-dependent tables that were previously joined only by loose text
-- fields (names, numbers) instead of real foreign keys, add the missing
-- chart_of_accounts table, and align seeded demo dates to the May-2026
-- timeline used across the app.

-- 1. HR master <-> login identity. employees (HR record) had no link to
--    user_profiles, so leave/payroll/claims (all keyed on user_profiles.id)
--    could not be joined to the HR employee record they belong to.
alter table public.employees
  add column if not exists user_id uuid references public.user_profiles(id) on delete set null;
create index if not exists employees_user_id_idx on public.employees(user_id);

-- 2. Claims two-stage approval (manager -> CFO). The table only had a single
--    approved_by; the app's SOP requires distinct manager and CFO approvers.
alter table public.claims
  add column if not exists manager_id uuid references public.user_profiles(id) on delete set null,
  add column if not exists cfo_approved_by uuid references public.user_profiles(id) on delete set null;
create index if not exists claims_manager_id_idx on public.claims(manager_id);

alter table public.nx_claims
  add column if not exists manager_id uuid references public.user_profiles(id) on delete set null;
create index if not exists nx_claims_manager_id_idx on public.nx_claims(manager_id);

-- 3. Payments <-> invoices. nx_payments referenced invoices only by a text
--    invoice_no; a real FK makes reconciliation a join instead of a string match.
alter table public.nx_payments
  add column if not exists invoice_id uuid references public.invoices(id) on delete set null;
create index if not exists nx_payments_invoice_id_idx on public.nx_payments(invoice_id);

-- 4. Purchase orders <-> budget lines. budget_line was a free-text label.
alter table public.purchase_orders
  add column if not exists budget_line_id uuid references public.budget_lines(id) on delete set null;
create index if not exists purchase_orders_budget_line_id_idx on public.purchase_orders(budget_line_id);

-- 5. Project tasks <-> assignees. assignee_name was text-only.
alter table public.project_tasks
  add column if not exists assignee_id uuid references public.user_profiles(id) on delete set null;
create index if not exists project_tasks_assignee_id_idx on public.project_tasks(assignee_id);

-- 6. Chart of accounts: journals post lines against account codes, but no
--    COA table existed server-side (it lived only in the frontend). This is
--    the anchor table the GL needs; journal lines stay jsonb for now, with
--    codes validated against this table by the accounting service.
create table if not exists public.chart_of_accounts (
  code text primary key,
  name text not null,
  account_type text not null check (account_type in ('Asset','Liability','Equity','Income','Expense')),
  opening_balance numeric not null default 0,
  is_active boolean not null default true,
  entity_id uuid references public.entities(id),
  created_at timestamptz not null default now()
);
alter table public.chart_of_accounts enable row level security;
drop policy if exists "coa_read_all_authenticated" on public.chart_of_accounts;
create policy "coa_read_all_authenticated" on public.chart_of_accounts
  for select to authenticated using (true);
drop policy if exists "coa_write_admin_cfo" on public.chart_of_accounts;
create policy "coa_write_admin_cfo" on public.chart_of_accounts
  for all to authenticated
  using (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','cfo')))
  with check (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','cfo')));

insert into public.chart_of_accounts (code, name, account_type, opening_balance) values
  ('1000','Bank — FNB Operating','Asset',18400000),
  ('1100','Accounts Receivable','Asset',12400000),
  ('1200','Fixed Assets — Equipment','Asset',4820000),
  ('1250','Accumulated Depreciation','Asset',-1240000),
  ('2000','Accounts Payable','Liability',-3180000),
  ('2050','Credit Card Payable','Liability',-2752),
  ('2100','VAT Control','Liability',-1080000),
  ('2200','PAYE / UIF Payable','Liability',-127383),
  ('3000','Share Capital','Equity',-1000000),
  ('3100','Retained Earnings','Equity',-27162617),
  ('4000','Revenue — SwiftPay','Income',-66100000),
  ('4100','Revenue — Billing SaaS','Income',-18600000),
  ('5000','Cost of Sales','Expense',24480000),
  ('6000','Salaries & Wages','Expense',9200000),
  ('6100','Depreciation','Expense',1240000),
  ('6200','Office & Admin','Expense',3130000)
on conflict (code) do nothing;

-- 7. Align seeded demo dates with the May-2026 timeline (shift +15 months,
--    matching the frontend's shifted seed data).
update public.nx_journals   set jdate = jdate + interval '15 months' where jdate < date '2026-01-01';
update public.nx_claims     set submitted        = submitted        + interval '15 months' where submitted        < date '2026-01-01';
update public.nx_claims     set manager_approval = manager_approval + interval '15 months' where manager_approval < date '2026-01-01';
update public.nx_claims     set cfo_approval     = cfo_approval     + interval '15 months' where cfo_approval     < date '2026-01-01';
update public.crm_deals     set close_date = close_date + interval '15 months' where close_date < date '2026-01-01';
update public.projects      set start_date = start_date + interval '15 months' where start_date < date '2026-01-01';
update public.projects      set end_date   = end_date   + interval '15 months' where end_date   < date '2026-01-01';
update public.projects      set due_date   = due_date   + interval '15 months' where due_date   < date '2026-01-01';
update public.project_tasks set due_date   = due_date   + interval '15 months' where due_date   < date '2026-01-01';
update public.invoices      set issue_date = issue_date + interval '15 months' where issue_date < date '2026-01-01';
update public.invoices      set due_date   = due_date   + interval '15 months' where due_date   < date '2026-01-01';
update public.invoices      set paid_date  = paid_date  + interval '15 months' where paid_date  < date '2026-01-01';
update public.budget_lines  set fiscal_year = '2026' where fiscal_year = '2025';
