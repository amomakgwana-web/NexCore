-- Realtime publication for collaboration tables + server-side API rate limiting
-- (Applied live via MCP; kept for reproducibility)
do $$ declare t text; begin
  foreach t in array array['nx_claims','nx_journals','nx_module_state','nx_sign_requests','notifications','nx_payments']
  loop begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; end; end loop;
end $$;
alter table public.nx_claims replica identity full;
alter table public.nx_module_state replica identity full;
alter table public.nx_sign_requests replica identity full;

create table if not exists public.nx_rate_limits (
  user_id uuid not null, action text not null, window_start timestamptz not null,
  hits int not null default 1, primary key (user_id, action, window_start));
alter table public.nx_rate_limits enable row level security;

create or replace function public.nx_check_rate(p_user uuid, p_action text, p_limit int, p_window_seconds int)
returns boolean language plpgsql security definer set search_path = public as $fn$
declare w_start timestamptz; current_hits int; begin
  w_start := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into nx_rate_limits (user_id, action, window_start, hits) values (p_user, p_action, w_start, 1)
    on conflict (user_id, action, window_start) do update set hits = nx_rate_limits.hits + 1
    returning hits into current_hits;
  delete from nx_rate_limits where window_start < now() - interval '1 day';
  return current_hits <= p_limit; end $fn$;
revoke execute on function public.nx_check_rate(uuid,text,int,int) from anon, authenticated;
