-- Revenue documents out of JSON (DATABASE_DESIGN.md gaps #1/#4):
-- real quotes table (was frontend-only QUOTES_DATA + nx_module_state) and
-- recurring_schedules (was a JSON blob under nx_module_state['billing-recurring']).

create table if not exists public.quotes (
  id uuid primary key default gen_random_uuid(),
  quote_number text not null unique,
  client_name text not null,
  contact_email text,
  value numeric not null default 0,
  status text not null default 'Draft' check (status in ('Draft','Sent','Negotiating','Accepted','Expired','Declined')),
  probability int not null default 50 check (probability between 0 and 100),
  owner_id uuid references public.user_profiles(id),
  owner_name text,
  issued_date date not null default current_date,
  expires_date date,
  converted_invoice_id uuid references public.invoices(id),
  entity_id uuid references public.entities(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists quotes_status_idx on public.quotes(status);
create index if not exists quotes_expires_idx on public.quotes(expires_date);

alter table public.quotes enable row level security;
drop policy if exists "quotes_read_authenticated" on public.quotes;
create policy "quotes_read_authenticated" on public.quotes
  for select to authenticated using (true);
drop policy if exists "quotes_write_sales_roles" on public.quotes;
create policy "quotes_write_sales_roles" on public.quotes
  for all to authenticated
  using (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','cfo','manager')))
  with check (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','cfo','manager')));

insert into public.quotes (quote_number, client_name, contact_email, value, status, probability, owner_name, issued_date, expires_date) values
  ('QT-2026-0041','Buffalo City Metro','scm@bufcity.gov.za',4200000,'Sent',65,'Bongani S.','2026-04-10','2026-05-10'),
  ('QT-2026-0040','City of Mangaung','finance@mangaung.co.za',2800000,'Accepted',95,'Bongani S.','2026-04-08','2026-05-08'),
  ('QT-2026-0039','Interfile Holdings','cfo@interfile.co.za',2400000,'Negotiating',80,'Bongani S.','2026-04-04','2026-05-04'),
  ('QT-2026-0038','Nelson Mandela Bay','finance@nmbm.gov.za',5800000,'Draft',50,'Bongani S.','2026-04-12','2026-06-12'),
  ('QT-2026-0037','Ekurhuleni Expand','scm@ekurhuleni.gov.za',3200000,'Expired',0,'Thabo M.','2026-03-01','2026-04-01')
on conflict (quote_number) do nothing;

create table if not exists public.recurring_schedules (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  frequency text not null check (frequency in ('Monthly','Quarterly','Annually')),
  next_date date not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (invoice_id)
);
create index if not exists recurring_schedules_next_date_idx on public.recurring_schedules(next_date) where active;

alter table public.recurring_schedules enable row level security;
drop policy if exists "rs_read_authenticated" on public.recurring_schedules;
create policy "rs_read_authenticated" on public.recurring_schedules
  for select to authenticated using (true);
drop policy if exists "rs_write_finance" on public.recurring_schedules;
create policy "rs_write_finance" on public.recurring_schedules
  for all to authenticated
  using (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','cfo')))
  with check (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','cfo')));

-- Migrate any existing JSON schedules (keyed by invoice uuid) into the table.
insert into public.recurring_schedules (invoice_id, frequency, next_date)
select (kv.key)::uuid, kv.value->>'frequency', (kv.value->>'nextDate')::date
from public.nx_module_state s, jsonb_each(s.state) kv
where s.module = 'billing-recurring'
  and kv.value ? 'frequency'
  and exists (select 1 from public.invoices i where i.id::text = kv.key)
on conflict (invoice_id) do nothing;
