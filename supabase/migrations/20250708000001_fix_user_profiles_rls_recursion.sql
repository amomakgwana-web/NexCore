-- Fix: "infinite recursion detected in policy for relation user_profiles"
--
-- Root cause: two policies defined ON user_profiles subqueried user_profiles
-- itself to resolve the caller's role (e.g. `EXISTS (SELECT 1 FROM
-- user_profiles up WHERE up.id = auth.uid() AND up.role = 'admin')`). Every
-- other original table's policies did the same subquery against
-- user_profiles, so any request touching them re-entered user_profiles' own
-- broken policies and recursed. All nx_-prefixed tables were unaffected
-- because their policies don't touch user_profiles this way.
--
-- Fix: route every role check through nx_role(), a SECURITY DEFINER function
-- owned by a bypassrls role, so the lookup never re-triggers RLS.

-- user_profiles (the actual recursion source)
drop policy if exists "Admins and CFO can view all profiles" on public.user_profiles;
create policy "Admins and CFO can view all profiles" on public.user_profiles
  for select using (nx_role() = ANY (ARRAY['admin','cfo','hr_manager']));

drop policy if exists "Admins can manage all profiles" on public.user_profiles;
create policy "Admins can manage all profiles" on public.user_profiles
  for all using (nx_role() = 'admin') with check (nx_role() = 'admin');

-- approvals
drop policy if exists "Managers resolve approvals" on public.approvals;
create policy "Managers resolve approvals" on public.approvals
  for update using (nx_role() = ANY (ARRAY['admin','cfo','manager']));

drop policy if exists "Requester and approvers read approvals" on public.approvals;
create policy "Requester and approvers read approvals" on public.approvals
  for select using (
    requester_id = (select auth.uid())
    or approver_id = (select auth.uid())
    or nx_role() = ANY (ARRAY['admin','cfo','manager'])
  );

-- audit_log
drop policy if exists "Admin and CFO read audit log" on public.audit_log;
create policy "Admin and CFO read audit log" on public.audit_log
  for select using (nx_role() = ANY (ARRAY['admin','cfo']));

-- budget_lines
drop policy if exists "Admin and CFO manage budget" on public.budget_lines;
create policy "Admin and CFO manage budget" on public.budget_lines
  for all using (nx_role() = ANY (ARRAY['admin','cfo'])) with check (nx_role() = ANY (ARRAY['admin','cfo']));

drop policy if exists "Finance roles read budget" on public.budget_lines;
create policy "Finance roles read budget" on public.budget_lines
  for select using (nx_role() = ANY (ARRAY['admin','cfo','manager']));

-- clock_events
drop policy if exists "Managers CFO Admin can view all clock events" on public.clock_events;
create policy "Managers CFO Admin can view all clock events" on public.clock_events
  for select using (nx_role() = ANY (ARRAY['admin','cfo','manager','hr_manager']));

-- crm_deals
drop policy if exists "Owner and managers update deals" on public.crm_deals;
create policy "Owner and managers update deals" on public.crm_deals
  for update using (
    owner_id = (select auth.uid()) or nx_role() = ANY (ARRAY['admin','manager'])
  );

drop policy if exists "Sales and managers read deals" on public.crm_deals;
create policy "Sales and managers read deals" on public.crm_deals
  for select using (
    owner_id = (select auth.uid()) or nx_role() = ANY (ARRAY['admin','cfo','manager'])
  );

-- employees
drop policy if exists "Admin and HR insert employees" on public.employees;
create policy "Admin and HR insert employees" on public.employees
  for insert with check (nx_role() = ANY (ARRAY['admin','hr_manager']));

drop policy if exists "Admin and HR update employees" on public.employees;
create policy "Admin and HR update employees" on public.employees
  for update using (nx_role() = ANY (ARRAY['admin','hr_manager']));

drop policy if exists "HR, Admin, CFO, Manager read employees" on public.employees;
create policy "HR, Admin, CFO, Manager read employees" on public.employees
  for select using (nx_role() = ANY (ARRAY['admin','cfo','hr_manager','manager']));

-- invoices
drop policy if exists "Finance manages invoices" on public.invoices;
create policy "Finance manages invoices" on public.invoices
  for all using (nx_role() = ANY (ARRAY['admin','cfo'])) with check (nx_role() = ANY (ARRAY['admin','cfo']));

drop policy if exists "Finance reads all invoices" on public.invoices;
create policy "Finance reads all invoices" on public.invoices
  for select using (nx_role() = ANY (ARRAY['admin','cfo','manager']));

-- leave_balances
drop policy if exists "Admin HR can manage leave balances" on public.leave_balances;
create policy "Admin HR can manage leave balances" on public.leave_balances
  for all using (nx_role() = ANY (ARRAY['admin','hr_manager'])) with check (nx_role() = ANY (ARRAY['admin','hr_manager']));

drop policy if exists "Admin HR can view all leave balances" on public.leave_balances;
create policy "Admin HR can view all leave balances" on public.leave_balances
  for select using (nx_role() = ANY (ARRAY['admin','hr_manager']));

-- leave_requests
drop policy if exists "Admin HR can view and manage all leave requests" on public.leave_requests;
create policy "Admin HR can view and manage all leave requests" on public.leave_requests
  for all using (nx_role() = ANY (ARRAY['admin','hr_manager'])) with check (nx_role() = ANY (ARRAY['admin','hr_manager']));

-- payroll_employees
drop policy if exists "CFO Admin can manage payroll employees" on public.payroll_employees;
create policy "CFO Admin can manage payroll employees" on public.payroll_employees
  for all using (nx_role() = ANY (ARRAY['admin','cfo'])) with check (nx_role() = ANY (ARRAY['admin','cfo']));

-- payroll_runs
drop policy if exists "CFO Admin can manage payroll runs" on public.payroll_runs;
create policy "CFO Admin can manage payroll runs" on public.payroll_runs
  for all using (nx_role() = ANY (ARRAY['admin','cfo'])) with check (nx_role() = ANY (ARRAY['admin','cfo']));

-- projects
drop policy if exists "Managers create projects" on public.projects;
create policy "Managers create projects" on public.projects
  for insert with check (nx_role() = ANY (ARRAY['admin','manager']));

drop policy if exists "Managers update projects" on public.projects;
create policy "Managers update projects" on public.projects
  for update using (nx_role() = ANY (ARRAY['admin','manager']));

-- vendors
drop policy if exists "Admin and CFO manage vendors" on public.vendors;
create policy "Admin and CFO manage vendors" on public.vendors
  for all using (nx_role() = ANY (ARRAY['admin','cfo'])) with check (nx_role() = ANY (ARRAY['admin','cfo']));

drop policy if exists "Finance and managers read vendors" on public.vendors;
create policy "Finance and managers read vendors" on public.vendors
  for select using (nx_role() = ANY (ARRAY['admin','cfo','manager','hr_manager']));
