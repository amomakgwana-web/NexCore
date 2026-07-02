-- Sprint A: persistent state store for v7-v9 modules
-- One row per module holding its full dataset as jsonb.
create table if not exists public.nx_module_state (
  module      text primary key,
  state       jsonb not null default '{}'::jsonb,
  updated_by  uuid references auth.users(id),
  updated_at  timestamptz not null default now()
);

alter table public.nx_module_state enable row level security;

drop policy if exists "nx_state_select" on public.nx_module_state;
create policy "nx_state_select" on public.nx_module_state
  for select to authenticated using (true);

drop policy if exists "nx_state_insert" on public.nx_module_state;
create policy "nx_state_insert" on public.nx_module_state
  for insert to authenticated with check (true);

drop policy if exists "nx_state_update" on public.nx_module_state;
create policy "nx_state_update" on public.nx_module_state
  for update to authenticated using (true) with check (true);

create or replace function public.nx_touch_state()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;

drop trigger if exists nx_state_touch on public.nx_module_state;
create trigger nx_state_touch before insert or update on public.nx_module_state
  for each row execute function public.nx_touch_state();
