-- deal_comments/deal_attachments/deal_members have no current frontend
-- writer (CRM collaboration still runs on the client-side CRM_DEAL_META
-- blob per the DB gap analysis), so tightening INSERT to require the
-- row's identity column match the inserting user carries zero functional
-- risk today and closes an identity-spoofing gap before these tables get
-- wired up for real.

drop policy if exists "dc_insert_authenticated" on public.deal_comments;
create policy "dc_insert_own" on public.deal_comments
  for insert to authenticated with check (author_id = auth.uid());

drop policy if exists "da_insert_authenticated" on public.deal_attachments;
create policy "da_insert_own" on public.deal_attachments
  for insert to authenticated with check (uploaded_by = auth.uid());

drop policy if exists "dm_insert_authenticated" on public.deal_members;
create policy "dm_insert_own" on public.deal_members
  for insert to authenticated with check (member_id = auth.uid() or public.nx_role() in ('admin','cfo','manager','hr_manager'));
