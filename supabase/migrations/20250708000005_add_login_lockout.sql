-- Real pre-auth brute-force throttling (NIST 800-63B §5.2.2): the login page
-- had no attempt tracking at all — an attacker could try unlimited
-- passwords against any email. Track attempts by email (not uid, since we
-- don't have one for a wrong password) and throttle after repeated failures.
create table if not exists public.login_attempts (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  success boolean not null,
  ip_address text,
  created_at timestamptz not null default now()
);
create index if not exists login_attempts_email_created_idx on public.login_attempts (email, created_at desc);

alter table public.login_attempts enable row level security;
create policy "No direct client access to login attempts" on public.login_attempts
  for all using (false) with check (false);

create or replace function public.record_login_attempt(p_email text, p_success boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.login_attempts(email, success) values (lower(trim(p_email)), p_success);
  -- keep the table bounded; attempts older than a day are irrelevant to lockout
  delete from public.login_attempts where created_at < now() - interval '1 day';
end;
$$;

create or replace function public.check_login_lockout(p_email text)
returns boolean
language sql security definer stable set search_path = public as $$
  select count(*) >= 5
  from public.login_attempts
  where email = lower(trim(p_email))
    and success = false
    and created_at > now() - interval '15 minutes';
$$;

grant execute on function public.record_login_attempt(text, boolean) to anon, authenticated;
grant execute on function public.check_login_lockout(text) to anon, authenticated;
