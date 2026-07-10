-- GL integrity (DATABASE_DESIGN.md gap #2): journal lines as real rows with
-- referential integrity to the chart of accounts, and debits=credits
-- enforced by the database itself, not just application code.

create table if not exists public.journal_lines (
  id uuid primary key default gen_random_uuid(),
  journal_id uuid not null references public.nx_journals(id) on delete cascade,
  account_code text not null references public.chart_of_accounts(code),
  debit numeric not null default 0 check (debit >= 0),
  credit numeric not null default 0 check (credit >= 0),
  check (debit = 0 or credit = 0),          -- a line is one side, not both
  created_at timestamptz not null default now()
);
create index if not exists journal_lines_journal_id_idx on public.journal_lines(journal_id);
create index if not exists journal_lines_account_code_idx on public.journal_lines(account_code);

alter table public.journal_lines enable row level security;
drop policy if exists "jl_read_authenticated" on public.journal_lines;
create policy "jl_read_authenticated" on public.journal_lines
  for select to authenticated using (true);
drop policy if exists "jl_write_finance" on public.journal_lines;
create policy "jl_write_finance" on public.journal_lines
  for all to authenticated
  using (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','cfo')))
  with check (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','cfo')));

-- Balance enforcement: after any change to a journal's lines, the journal
-- must balance. Deferred to transaction end so multi-line inserts work.
create or replace function public.enforce_journal_balance()
returns trigger language plpgsql as $$
declare
  jid uuid := coalesce(new.journal_id, old.journal_id);
  dr numeric; cr numeric;
begin
  select coalesce(sum(debit),0), coalesce(sum(credit),0) into dr, cr
  from public.journal_lines where journal_id = jid;
  if round(dr - cr, 2) <> 0 then
    raise exception 'journal % is unbalanced: debits % <> credits %', jid, dr, cr;
  end if;
  return null;
end; $$;

drop trigger if exists journal_balance_check on public.journal_lines;
create constraint trigger journal_balance_check
  after insert or update or delete on public.journal_lines
  deferrable initially deferred
  for each row execute function public.enforce_journal_balance();

-- Backfill from the existing jsonb lines.
insert into public.journal_lines (journal_id, account_code, debit, credit)
select j.id, l->>'acct', coalesce((l->>'debit')::numeric,0), coalesce((l->>'credit')::numeric,0)
from public.nx_journals j, jsonb_array_elements(j.lines) l
where not exists (select 1 from public.journal_lines x where x.journal_id = j.id);
