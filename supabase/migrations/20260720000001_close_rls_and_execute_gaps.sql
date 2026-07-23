-- Close two real exposure gaps surfaced by the Supabase security advisor:
--
-- 1. deal_comments/deal_attachments/deal_members had `for all ... using (true)
--    with check (true)` for the `authenticated` role — any signed-in user
--    (any role) could read, edit, or delete any other user's comments,
--    attachments, or deal membership on any deal, not just their own.
--    Tightened so SELECT/INSERT stay open to any authenticated user (matches
--    the app's existing collaborative-CRM behaviour), but UPDATE/DELETE are
--    now restricted to the row's own author/uploader/member, or an
--    admin/manager/CFO/HR override.
--
-- 2. audit_write, nx_check_rate, and rls_auto_enable were callable via
--    PostgREST RPC by both anon and authenticated — none of the three are
--    ever called from the client (writeAudit() inserts into audit_log
--    directly under its own RLS policy instead), so this was pure excess
--    privilege: an anonymous caller could spam audit_log with fabricated
--    entries, manipulate another user's rate-limit counters, or invoke a
--    maintenance-only function, all without signing in. Execute is revoked
--    for anon/authenticated; the functions remain usable internally
--    (triggers, service_role, direct SQL) where they're actually needed.

drop policy if exists "dc_rw_authenticated" on public.deal_comments;
create policy "dc_select_authenticated" on public.deal_comments
  for select to authenticated using (true);
create policy "dc_insert_authenticated" on public.deal_comments
  for insert to authenticated with check (true);
create policy "dc_update_own_or_privileged" on public.deal_comments
  for update to authenticated
  using (author_id = auth.uid() or public.nx_role() in ('admin','cfo','manager','hr_manager'))
  with check (author_id = auth.uid() or public.nx_role() in ('admin','cfo','manager','hr_manager'));
create policy "dc_delete_own_or_privileged" on public.deal_comments
  for delete to authenticated
  using (author_id = auth.uid() or public.nx_role() in ('admin','cfo','manager','hr_manager'));

drop policy if exists "da_rw_authenticated" on public.deal_attachments;
create policy "da_select_authenticated" on public.deal_attachments
  for select to authenticated using (true);
create policy "da_insert_authenticated" on public.deal_attachments
  for insert to authenticated with check (true);
create policy "da_update_own_or_privileged" on public.deal_attachments
  for update to authenticated
  using (uploaded_by = auth.uid() or public.nx_role() in ('admin','cfo','manager','hr_manager'))
  with check (uploaded_by = auth.uid() or public.nx_role() in ('admin','cfo','manager','hr_manager'));
create policy "da_delete_own_or_privileged" on public.deal_attachments
  for delete to authenticated
  using (uploaded_by = auth.uid() or public.nx_role() in ('admin','cfo','manager','hr_manager'));

drop policy if exists "dm_rw_authenticated" on public.deal_members;
create policy "dm_select_authenticated" on public.deal_members
  for select to authenticated using (true);
create policy "dm_insert_authenticated" on public.deal_members
  for insert to authenticated with check (true);
create policy "dm_update_own_or_privileged" on public.deal_members
  for update to authenticated
  using (member_id = auth.uid() or public.nx_role() in ('admin','cfo','manager','hr_manager'))
  with check (member_id = auth.uid() or public.nx_role() in ('admin','cfo','manager','hr_manager'));
create policy "dm_delete_own_or_privileged" on public.deal_members
  for delete to authenticated
  using (member_id = auth.uid() or public.nx_role() in ('admin','cfo','manager','hr_manager'));

revoke execute on function public.audit_write(text, text, text, numeric, text, jsonb) from anon, authenticated;
revoke execute on function public.nx_check_rate(uuid, text, integer, integer) from anon, authenticated;
revoke execute on function public.rls_auto_enable() from anon, authenticated;
