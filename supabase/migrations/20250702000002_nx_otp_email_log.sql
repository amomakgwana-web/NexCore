-- Sprint B: OTP storage + server-side email delivery log
create table if not exists public.nx_otp (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id),
  code_hash   text not null,
  purpose     text not null default 'confirm',
  expires_at  timestamptz not null default now() + interval '5 minutes',
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists nx_otp_user_idx on public.nx_otp(user_id, expires_at desc);

alter table public.nx_otp enable row level security;
-- No client policies: only the service role (Edge Function) touches this table.

create table if not exists public.nx_email_log (
  id          uuid primary key default gen_random_uuid(),
  sent_by     uuid references auth.users(id),
  recipient   text not null,
  subject     text not null,
  provider    text not null default 'simulated',
  provider_id text,
  status      text not null default 'queued',
  created_at  timestamptz not null default now()
);

alter table public.nx_email_log enable row level security;

drop policy if exists "email_log_select" on public.nx_email_log;
create policy "email_log_select" on public.nx_email_log
  for select to authenticated using (true);
