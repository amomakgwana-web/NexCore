-- Sprint C: gateway payments captured by webhook
create table if not exists public.nx_payments (
  id           uuid primary key default gen_random_uuid(),
  invoice_no   text not null,
  provider     text not null default 'payfast',
  amount       numeric(14,2),
  status       text not null default 'pending',
  payer_email  text,
  raw          jsonb,
  reconciled   boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists nx_payments_inv_idx on public.nx_payments(invoice_no, created_at desc);

alter table public.nx_payments enable row level security;

drop policy if exists "payments_select" on public.nx_payments;
create policy "payments_select" on public.nx_payments
  for select to authenticated using (true);

drop policy if exists "payments_reconcile" on public.nx_payments;
create policy "payments_reconcile" on public.nx_payments
  for update to authenticated using (true) with check (true);
-- Inserts happen only via the service-role webhook function.
