-- Production Foundation: relational tables + role-enforced RLS for the
-- money-touching modules (claims, payroll, GL) and onboarded employees.
-- (Applied to the live project; kept here for reproducibility.)

create or replace function public.nx_role()
returns text language sql stable security definer as $$
  select coalesce((select role from public.user_profiles where id = auth.uid()), 'staff');
$$;

create table if not exists public.nx_claims (
  id               uuid primary key default gen_random_uuid(),
  claim_no         text unique not null,
  user_id          uuid references auth.users(id),
  emp_name         text not null,
  category         text not null,
  description      text not null,
  amount           numeric(14,2) not null check (amount > 0),
  receipts         int not null default 1,
  receipt_path     text,
  status           text not null default 'Pending Manager',
  submitted        date not null default current_date,
  manager_approval date,
  cfo_approval     date,
  paid             boolean not null default false,
  created_at       timestamptz not null default now()
);
alter table public.nx_claims enable row level security;
create policy "claims_select" on public.nx_claims for select to authenticated using (true);
create policy "claims_insert_own" on public.nx_claims for insert to authenticated
  with check (user_id = auth.uid());
create policy "claims_update_approvers" on public.nx_claims for update to authenticated
  using (public.nx_role() in ('admin','cfo','manager','hr_manager'))
  with check (public.nx_role() in ('admin','cfo','manager','hr_manager'));

create table if not exists public.nx_journals (
  id         uuid primary key default gen_random_uuid(),
  ref        text not null,
  jdate      date not null default current_date,
  narration  text not null,
  lines      jsonb not null,
  posted_by  uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create or replace function public.nx_journal_balanced()
returns trigger language plpgsql as $$
declare dr numeric; cr numeric;
begin
  select coalesce(sum((l->>'debit')::numeric),0), coalesce(sum((l->>'credit')::numeric),0)
    into dr, cr from jsonb_array_elements(new.lines) l;
  if abs(dr - cr) > 0.01 then
    raise exception 'journal out of balance: DR % vs CR %', dr, cr;
  end if;
  new.posted_by := coalesce(new.posted_by, auth.uid());
  return new;
end $$;
create trigger nx_journal_balance_check before insert or update on public.nx_journals
  for each row execute function public.nx_journal_balanced();
alter table public.nx_journals enable row level security;
create policy "journals_select" on public.nx_journals for select to authenticated using (true);
create policy "journals_insert_finance" on public.nx_journals for insert to authenticated
  with check (public.nx_role() in ('admin','cfo'));

create table if not exists public.nx_payroll_runs (
  id          uuid primary key default gen_random_uuid(),
  period      text not null,
  headcount   int not null,
  gross       numeric(14,2) not null,
  paye        numeric(14,2) not null,
  uif         numeric(14,2) not null,
  net         numeric(14,2) not null,
  status      text not null default 'released',
  released_by uuid references auth.users(id),
  created_at  timestamptz not null default now()
);
alter table public.nx_payroll_runs enable row level security;
create policy "payruns_select" on public.nx_payroll_runs for select to authenticated
  using (public.nx_role() in ('admin','cfo','manager','hr_manager'));
create policy "payruns_insert" on public.nx_payroll_runs for insert to authenticated
  with check (public.nx_role() in ('admin','cfo','hr_manager'));

create table if not exists public.nx_employees (
  id            uuid primary key default gen_random_uuid(),
  emp_no        text unique not null,
  full_name     text not null,
  email         text,
  department    text,
  role_title    text,
  basic         numeric(14,2) not null default 0,
  medical       numeric(14,2) not null default 0,
  retirement    numeric(14,2) not null default 0,
  leave_balance numeric(6,2) not null default 0,
  start_date    date,
  status        text not null default 'Onboarding',
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now()
);
alter table public.nx_employees enable row level security;
create policy "employees_select" on public.nx_employees for select to authenticated using (true);
create policy "employees_write_hr" on public.nx_employees for insert to authenticated
  with check (public.nx_role() in ('admin','hr_manager','manager'));
create policy "employees_update_hr" on public.nx_employees for update to authenticated
  using (public.nx_role() in ('admin','hr_manager','manager'))
  with check (public.nx_role() in ('admin','hr_manager','manager'));

insert into storage.buckets (id, name, public)
  values ('receipts','receipts',false), ('vault','vault',false)
  on conflict (id) do nothing;
create policy "receipts_rw" on storage.objects for all to authenticated
  using (bucket_id in ('receipts','vault'))
  with check (bucket_id in ('receipts','vault'));
