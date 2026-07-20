-- Departments as a real table (DATABASE_DESIGN.md gap #6) and CRM
-- collaboration child tables (gap #5) so deal comments/files/members stop
-- living in a client-side JSON blob.

create table if not exists public.departments (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  entity_id uuid references public.entities(id),
  manager_id uuid references public.user_profiles(id),
  created_at timestamptz not null default now()
);
alter table public.departments enable row level security;
drop policy if exists "dept_read_authenticated" on public.departments;
create policy "dept_read_authenticated" on public.departments
  for select to authenticated using (true);
drop policy if exists "dept_write_admin_hr" on public.departments;
create policy "dept_write_admin_hr" on public.departments
  for all to authenticated
  using (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','hr_manager')))
  with check (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in ('admin','hr_manager')));

-- Backfill from every distinct department string already in use, plus the
-- app's canonical list (live tables can be empty in a fresh project).
insert into public.departments (name)
select distinct department from public.employees where department is not null and department <> ''
union
select distinct department from public.budget_lines where department is not null and department <> ''
on conflict (name) do nothing;
insert into public.departments (name) values
  ('Engineering'),('Operations'),('HR'),('Finance'),('Sales'),('Marketing'),
  ('IT & Systems'),('Legal & Compliance'),('Executive Office'),('Human Resources')
on conflict (name) do nothing;

-- FK columns alongside the legacy text (text kept until frontend reads the FK).
alter table public.employees
  add column if not exists department_id uuid references public.departments(id) on delete set null;
alter table public.budget_lines
  add column if not exists department_id uuid references public.departments(id) on delete set null;
create index if not exists employees_department_id_idx on public.employees(department_id);
create index if not exists budget_lines_department_id_idx on public.budget_lines(department_id);

update public.employees e set department_id = d.id
from public.departments d where d.name = e.department and e.department_id is null;
update public.budget_lines b set department_id = d.id
from public.departments d where d.name = b.department and b.department_id is null;

-- CRM collaboration: comments, attachments, members per deal.
create table if not exists public.deal_comments (
  id uuid primary key default gen_random_uuid(),
  deal_id uuid not null references public.crm_deals(id) on delete cascade,
  author_id uuid references public.user_profiles(id),
  author_name text,
  body text not null,
  created_at timestamptz not null default now()
);
create index if not exists deal_comments_deal_id_idx on public.deal_comments(deal_id);

create table if not exists public.deal_attachments (
  id uuid primary key default gen_random_uuid(),
  deal_id uuid not null references public.crm_deals(id) on delete cascade,
  file_name text not null,
  storage_path text,
  uploaded_by uuid references public.user_profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists deal_attachments_deal_id_idx on public.deal_attachments(deal_id);

create table if not exists public.deal_members (
  id uuid primary key default gen_random_uuid(),
  deal_id uuid not null references public.crm_deals(id) on delete cascade,
  member_id uuid references public.user_profiles(id),
  member_name text,
  role text not null default 'collaborator' check (role in ('owner','collaborator','watcher')),
  created_at timestamptz not null default now(),
  unique (deal_id, member_id)
);
create index if not exists deal_members_deal_id_idx on public.deal_members(deal_id);

alter table public.deal_comments enable row level security;
alter table public.deal_attachments enable row level security;
alter table public.deal_members enable row level security;

drop policy if exists "dc_rw_authenticated" on public.deal_comments;
create policy "dc_rw_authenticated" on public.deal_comments
  for all to authenticated using (true) with check (true);
drop policy if exists "da_rw_authenticated" on public.deal_attachments;
create policy "da_rw_authenticated" on public.deal_attachments
  for all to authenticated using (true) with check (true);
drop policy if exists "dm_rw_authenticated" on public.deal_members;
create policy "dm_rw_authenticated" on public.deal_members
  for all to authenticated using (true) with check (true);
