-- External e-signature requests: a tokenised signing link anyone can open
-- on any device. The sign-doc Edge Function (service role) handles the
-- public signing page; clients only read status.
create table if not exists public.nx_sign_requests (
  id           uuid primary key default gen_random_uuid(),
  token        text unique not null,
  doc_type     text not null default 'contract',
  doc_title    text not null,
  doc_html     text not null,
  party_name   text not null,
  party_email  text,
  status       text not null default 'sent',
  signature    text,
  signed_at    timestamptz,
  signer_ip    text,
  requested_by uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '14 days'
);
create index if not exists nx_sign_token_idx on public.nx_sign_requests(token);
alter table public.nx_sign_requests enable row level security;
create policy "sign_select" on public.nx_sign_requests
  for select to authenticated using (true);
create policy "sign_insert" on public.nx_sign_requests
  for insert to authenticated with check (requested_by = auth.uid());
-- Updates (the actual signing) happen only via the service-role Edge Function.
