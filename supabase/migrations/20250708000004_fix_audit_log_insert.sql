-- audit_log had RLS enabled with only a SELECT policy, so every writeAudit()
-- insert across the app (~70+ call sites) has been silently blocked by RLS
-- the whole time — the code never checked the returned error. Any
-- authenticated user should be able to write their own audit trail entries;
-- reading remains restricted to admin/cfo per the existing policy.
create policy "Authenticated users write audit log" on public.audit_log
  for insert with check ((select auth.uid()) is not null);

-- The check constraint only allowed 'info'/'warning'/'critical', but every
-- writeAudit() call site in the client (~60+ calls) actually passes
-- 'low'/'medium'/'high'/'Info' — meaning even with the INSERT policy above,
-- every single insert would still fail this constraint. Widen it to the
-- vocabulary the app actually uses instead of rewriting every call site.
alter table public.audit_log drop constraint if exists audit_log_severity_check;
alter table public.audit_log add constraint audit_log_severity_check
  check (lower(severity) = ANY (ARRAY['low','medium','high','info','warning','critical']));
