-- Managers had no RLS path to review leave at all (only admin/hr_manager could),
-- so a manager clicking Approve/Reject always failed with a permission error.
-- Add a manager-scoped policy for the first review stage, matching the
-- Claims SOP's manager -> final-approver chain: manager moves 'pending' to
-- 'manager_approved' or 'rejected'; admin/hr_manager (already unrestricted)
-- perform the final sign-off from 'manager_approved' to 'approved'.
create policy "Manager can review pending leave requests" on public.leave_requests
  for update
  using (nx_role() = 'manager' and status = 'pending')
  with check (nx_role() = 'manager' and status in ('manager_approved', 'rejected'));

-- Sick-leave medical certificate tracking: whether a medical letter has been
-- requested from the employee, and the stored report URL once attached.
alter table public.leave_requests add column if not exists medical_requested boolean not null default false;
alter table public.leave_requests add column if not exists medical_report_url text;
