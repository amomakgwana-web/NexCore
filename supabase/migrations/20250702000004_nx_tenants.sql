-- Sprint E: multi-tenant white-labelling
create table if not exists public.nx_tenants (
  id          uuid primary key default gen_random_uuid(),
  slug        text unique not null,
  domain      text unique,
  brand       jsonb not null default '{}'::jsonb,   -- {name, initials, accent, hidePoweredBy}
  templates   jsonb not null default '{}'::jsonb,   -- NX_TPL document/email templates
  created_by  uuid references auth.users(id),
  updated_at  timestamptz not null default now()
);

alter table public.nx_tenants enable row level security;

-- Brand resolution happens before login, so anon may read brand data.
-- Brands are public by nature (they render on the login screen).
drop policy if exists "tenants_public_read" on public.nx_tenants;
create policy "tenants_public_read" on public.nx_tenants
  for select to anon, authenticated using (true);

drop policy if exists "tenants_insert" on public.nx_tenants;
create policy "tenants_insert" on public.nx_tenants
  for insert to authenticated with check (true);

drop policy if exists "tenants_update" on public.nx_tenants;
create policy "tenants_update" on public.nx_tenants
  for update to authenticated using (true) with check (true);

create or replace function public.nx_touch_tenant()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if new.created_by is null then new.created_by := auth.uid(); end if;
  return new;
end $$;

drop trigger if exists nx_tenant_touch on public.nx_tenants;
create trigger nx_tenant_touch before insert or update on public.nx_tenants
  for each row execute function public.nx_touch_tenant();
