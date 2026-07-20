-- Payroll period control (DATABASE_DESIGN.md gap #3): a periods table with
-- an open->approved->locked lifecycle, a hard uniqueness guard against
-- paying the same employee twice in one period, and a trigger blocking
-- runs into non-open periods. Also gives the attendance-reconciliation
-- approval gate (manager + CFO) a real home instead of client-side state.

create table if not exists public.payroll_periods (
  id uuid primary key default gen_random_uuid(),
  period_month int not null check (period_month between 1 and 12),
  period_year int not null check (period_year between 2020 and 2100),
  status text not null default 'open' check (status in ('open','approved','locked')),
  manager_approved_by uuid references public.user_profiles(id),
  manager_approved_at timestamptz,
  cfo_approved_by uuid references public.user_profiles(id),
  cfo_approved_at timestamptz,
  locked_at timestamptz,
  created_at timestamptz not null default now(),
  unique (period_month, period_year)
);

alter table public.payroll_periods enable row level security;
drop policy if exists "pp_read_authenticated" on public.payroll_periods;
create policy "pp_read_authenticated" on public.payroll_periods
  for select to authenticated using (true);
drop policy if exists "pp_write_payroll_roles" on public.payroll_periods;
create policy "pp_write_payroll_roles" on public.payroll_periods
  for all to authenticated
  using (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','cfo','hr_manager')))
  with check (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','cfo','hr_manager')));

-- One run per employee per period, enforced by the database.
create unique index if not exists payroll_runs_one_per_employee_period
  on public.payroll_runs (employee_id, period_month, period_year);

-- Block processing into a period that is not open (or does not exist).
create or replace function public.enforce_open_payroll_period()
returns trigger language plpgsql as $$
declare st text;
begin
  select status into st from public.payroll_periods
  where period_month = new.period_month and period_year = new.period_year;
  if st is null then
    raise exception 'payroll period %/% does not exist — create it before processing runs', new.period_year, new.period_month;
  elsif st <> 'open' then
    raise exception 'payroll period %/% is % — runs can only be processed into an open period', new.period_year, new.period_month, st;
  end if;
  return new;
end; $$;

drop trigger if exists payroll_run_period_check on public.payroll_runs;
create trigger payroll_run_period_check
  before insert on public.payroll_runs
  for each row execute function public.enforce_open_payroll_period();

-- Seed the demo timeline: locked history (Feb-Apr 2026) and the open May 2026 period.
insert into public.payroll_periods (period_month, period_year, status, locked_at) values
  (2, 2026, 'locked', now()), (3, 2026, 'locked', now()), (4, 2026, 'locked', now())
on conflict (period_month, period_year) do nothing;
insert into public.payroll_periods (period_month, period_year, status) values (5, 2026, 'open')
on conflict (period_month, period_year) do nothing;
