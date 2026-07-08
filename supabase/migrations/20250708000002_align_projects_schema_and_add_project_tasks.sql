-- Fix: 400 error on `projects?select=*,tasks:project_tasks(...)`.
--
-- The live `projects` table predated the current UI: it was missing the
-- columns the UI maps (project_code, progress, lead_name, budget_total,
-- budget_spent, sprint_name, due_date, color), used a different status
-- vocabulary (active/on_hold/completed/cancelled vs. the UI's
-- Active/Planning/Blocked/Complete), and its child `project_tasks` table
-- didn't exist at all, so PostgREST couldn't resolve the embedded
-- `tasks:project_tasks(...)` relationship. Table was empty in production,
-- so realign it to the UI rather than rewrite the render/mapping code.

alter table public.projects
  add column if not exists project_code text unique,
  add column if not exists progress int default 0,
  add column if not exists lead_name text,
  add column if not exists budget_total numeric(14,2) default 0,
  add column if not exists budget_spent numeric(14,2) default 0,
  add column if not exists sprint_name text,
  add column if not exists due_date date,
  add column if not exists color text default '#3B82F6';

alter table public.projects drop constraint if exists projects_status_check;
alter table public.projects add constraint projects_status_check
  check (status = ANY (ARRAY['Active','Planning','Blocked','Complete']));

alter table public.projects alter column status set default 'Planning';

create table if not exists public.project_tasks (
  id             uuid primary key default gen_random_uuid(),
  project_id     uuid references public.projects(id) on delete cascade,
  title          text not null,
  status         text default 'todo',
  assignee_name  text,
  due_date       date,
  created_at     timestamptz default now()
);

alter table public.project_tasks enable row level security;

drop policy if exists "Authenticated read" on public.project_tasks;
create policy "Authenticated read" on public.project_tasks
  for select using ((select auth.uid()) is not null);

drop policy if exists "Admin/manager write" on public.project_tasks;
create policy "Admin/manager write" on public.project_tasks
  for all using (nx_role() = ANY (ARRAY['admin','manager']))
  with check (nx_role() = ANY (ARRAY['admin','manager']));

alter publication supabase_realtime add table public.project_tasks;
alter table public.project_tasks replica identity full;

-- demo seed so the Projects module isn't empty
insert into public.projects (project_code, name, status, progress, lead_name, budget_total, budget_spent, sprint_name, due_date, color)
values
  ('PRJ-001', 'ERP Platform Rollout', 'Active', 62, 'Amo Makgwana', 850000, 512000, 'Sprint 4', current_date + interval '21 days', '#3B82F6'),
  ('PRJ-002', 'Payroll Automation', 'Planning', 40, 'Thandi Nkosi', 320000, 118000, 'Sprint 2', current_date + interval '35 days', '#10B981'),
  ('PRJ-003', 'Office Access Upgrade', 'Blocked', 10, 'Sipho Dlamini', 150000, 12000, 'Sprint 1', current_date + interval '60 days', '#F59E0B')
on conflict (project_code) do nothing;

insert into public.project_tasks (project_id, title, status, assignee_name)
select p.id, t.title, t.status, t.assignee_name
from public.projects p
cross join lateral (values
  ('Kickoff & scoping', 'done', p.lead_name),
  ('Build core flow', 'in_progress', p.lead_name),
  ('QA & review', 'todo', p.lead_name)
) as t(title, status, assignee_name)
where not exists (select 1 from public.project_tasks pt where pt.project_id = p.id);
