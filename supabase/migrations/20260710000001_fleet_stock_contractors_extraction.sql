-- Extract the last JSON-blob modules into real tables (DATABASE_DESIGN.md
-- gap #1 remainder): fleet, stock and contractors, seeded from the app's
-- May-2026 demo data. (Applied live via MCP as fleet_stock_contractors_extraction.)

create table if not exists public.fleet_vehicles (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  registration text not null,
  model text not null,
  driver_name text,
  driver_id uuid references public.user_profiles(id),
  odometer_km int not null default 0,
  service_due_km int,
  service_due_date date,
  status text not null default 'OK' check (status in ('OK','Due Soon','Overdue','In Service','Retired')),
  fuel_budget_monthly numeric not null default 0,
  device jsonb not null default '{}'::jsonb,
  entity_id uuid references public.entities(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.fuel_log (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.fleet_vehicles(id) on delete cascade,
  log_date date not null,
  odometer_km int,
  litres numeric not null,
  cost numeric not null,
  station text,
  created_at timestamptz not null default now()
);
create index if not exists fuel_log_vehicle_id_idx on public.fuel_log(vehicle_id);
create index if not exists fuel_log_date_idx on public.fuel_log(log_date);

create table if not exists public.stock_items (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique,
  name text not null,
  category text,
  on_hand int not null default 0,
  reorder_level int not null default 0,
  max_level int,
  unit text,
  unit_cost numeric not null default 0,
  entity_id uuid references public.entities(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  stock_item_id uuid not null references public.stock_items(id) on delete cascade,
  moved_at date not null default current_date,
  movement_type text not null check (movement_type in ('Receipt','Usage','Adjustment','Disposal')),
  quantity int not null,
  reference text,
  created_at timestamptz not null default now()
);
create index if not exists stock_movements_item_idx on public.stock_movements(stock_item_id);

create table if not exists public.contractors (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  full_name text not null,
  role_title text,
  country text,
  currency text not null default 'ZAR',
  rate numeric not null default 0,
  rate_type text not null default 'Monthly' check (rate_type in ('Monthly','Daily','Hourly')),
  start_date date,
  end_date date,
  status text not null default 'Active' check (status in ('Active','Onboarding','Ending Soon','Ended')),
  employment_type text check (employment_type in ('Contractor','EOR Employee')),
  eor_entity text,
  docs jsonb not null default '{}'::jsonb,
  entity_id uuid references public.entities(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date is null or start_date is null or end_date >= start_date)
);

create table if not exists public.contractor_pay_runs (
  id uuid primary key default gen_random_uuid(),
  run_code text not null unique,
  period text not null,
  run_date date,
  total_zar numeric not null default 0,
  status text not null default 'Draft' check (status in ('Draft','Approved','Paid')),
  created_at timestamptz not null default now()
);

create table if not exists public.contractor_pay_lines (
  id uuid primary key default gen_random_uuid(),
  pay_run_id uuid not null references public.contractor_pay_runs(id) on delete cascade,
  contractor_id uuid not null references public.contractors(id),
  amount_local numeric not null,
  currency text not null,
  amount_zar numeric not null,
  created_at timestamptz not null default now(),
  unique (pay_run_id, contractor_id)
);
create index if not exists contractor_pay_lines_run_idx on public.contractor_pay_lines(pay_run_id);

do $$
declare t text;
begin
  foreach t in array array['fleet_vehicles','fuel_log','stock_items','stock_movements','contractors','contractor_pay_runs','contractor_pay_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "%s_read" on public.%I', t, t);
    execute format('create policy "%s_read" on public.%I for select to authenticated using (true)', t, t);
    execute format('drop policy if exists "%s_write" on public.%I', t, t);
    execute format('create policy "%s_write" on public.%I for all to authenticated
      using (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in (''admin'',''cfo'',''manager'',''hr_manager'')))
      with check (exists (select 1 from public.user_profiles p where p.id = auth.uid() and p.role in (''admin'',''cfo'',''manager'',''hr_manager'')))', t, t);
  end loop;
end $$;

insert into public.fleet_vehicles (code, registration, model, driver_name, odometer_km, service_due_km, service_due_date, status, fuel_budget_monthly, device) values
  ('FL-01','JX 42 HG GP','Toyota Hilux 2.4 GD-6','Thabo M.',84200,90000,'2026-07-15','OK',6000,'{"model":"Geotab GO9 (fuel + telematics)","status":"Online","tankCapacity":80,"calibrated":true}'),
  ('FL-02','KZ 18 PL GP','VW Polo Vivo 1.4','Nomsa P.',118400,120000,'2026-05-20','Due Soon',4000,'{"model":"Digital Matter Fuel Sense","status":"Online","tankCapacity":45,"calibrated":true}'),
  ('FL-03','HT 77 WC CA','Ford Ranger 2.0 BiT','Kagiso D.',64100,60000,'2026-04-10','Overdue',5500,'{"model":"None installed","status":"Not installed","tankCapacity":80,"calibrated":false}'),
  ('FL-04','LM 03 KN ZN','Nissan NP200 1.6','Pool vehicle',41900,45000,'2026-09-01','OK',3000,'{"model":"None installed","status":"Not installed","tankCapacity":60,"calibrated":false}')
on conflict (code) do nothing;

insert into public.fuel_log (vehicle_id, log_date, odometer_km, litres, cost, station)
select v.id, x.log_date::date, x.odo, x.litres, x.cost, x.station
from (values
  ('FL-01','2026-04-28',84200,68,1577,'Engen Rivonia'),
  ('FL-02','2026-04-27',118400,42,974,'Shell Sandton'),
  ('FL-01','2026-04-21',83480,65,1508,'BP Midrand'),
  ('FL-03','2026-04-20',64100,74,1716,'Sasol Centurion'),
  ('FL-02','2026-04-18',117820,40,928,'Engen Rosebank')
) as x(code, log_date, odo, litres, cost, station)
join public.fleet_vehicles v on v.code = x.code
where not exists (select 1 from public.fuel_log f where f.vehicle_id = v.id and f.log_date = x.log_date::date and f.litres = x.litres);

insert into public.stock_items (sku, name, category, on_hand, reorder_level, max_level, unit, unit_cost) values
  ('SKU-OFF-001','Paper A4 (ream)','Stationery',12,50,200,'ream',89),
  ('SKU-OFF-002','Printer Toner HP','Stationery',3,5,20,'unit',1200),
  ('SKU-IT-021','Network Cable Cat6','IT',240,50,500,'m',12),
  ('SKU-IT-022','USB-C Hub 7-port','IT',8,10,30,'unit',890),
  ('SKU-CLEAN-01','Hand Sanitizer 1L','Facilities',18,20,50,'bottle',45),
  ('SKU-IT-023','Wireless Keyboard','IT',4,5,20,'unit',650)
on conflict (sku) do nothing;

insert into public.stock_movements (stock_item_id, moved_at, movement_type, quantity)
select s.id, x.moved_at::date, x.mtype, x.qty
from (values
  ('SKU-OFF-001','2026-04-02','Receipt',150),('SKU-OFF-001','2026-04-18','Usage',-88),('SKU-OFF-001','2026-04-27','Usage',-50),
  ('SKU-OFF-002','2026-04-05','Receipt',12),('SKU-OFF-002','2026-04-22','Usage',-9),
  ('SKU-IT-021','2026-04-10','Receipt',300),('SKU-IT-021','2026-04-25','Usage',-60),
  ('SKU-IT-022','2026-04-08','Receipt',15),('SKU-IT-022','2026-04-20','Usage',-7),
  ('SKU-CLEAN-01','2026-04-03','Receipt',40),('SKU-CLEAN-01','2026-04-26','Usage',-22),
  ('SKU-IT-023','2026-04-06','Receipt',10),('SKU-IT-023','2026-04-19','Usage',-6)
) as x(sku, moved_at, mtype, qty)
join public.stock_items s on s.sku = x.sku
where not exists (select 1 from public.stock_movements m where m.stock_item_id = s.id and m.moved_at = x.moved_at::date and m.quantity = x.qty);

insert into public.contractors (code, full_name, role_title, country, currency, rate, rate_type, start_date, end_date, status, employment_type, eor_entity) values
  ('CTR-001','Maria Santos','UX Designer','Portugal','EUR',4200,'Monthly','2025-09-01','2026-09-01','Active','EOR Employee','RemotePT Legal Services Lda'),
  ('CTR-002','Raj Patel','Backend Engineer','India','INR',280000,'Monthly','2025-06-15','2026-06-15','Active','EOR Employee','IndiaEOR Services Pvt Ltd'),
  ('CTR-003','Grace Wanjiru','Data Analyst','Kenya','KES',350000,'Monthly','2025-12-01','2026-12-01','Active','Contractor',null),
  ('CTR-004','Chidi Okafor','Mobile Developer','Nigeria','NGN',2800000,'Monthly','2026-02-01','2026-05-28','Ending Soon','EOR Employee','NaijaWorks EOR Ltd'),
  ('CTR-005','Ana Oliveira','QA Engineer','Brazil','BRL',9500,'Monthly','2026-04-06','2027-04-06','Onboarding','Contractor',null),
  ('CTR-006','Piotr Kowalski','DevOps Engineer','Poland','EUR',5100,'Monthly','2025-10-01','2026-10-01','Active','EOR Employee','PolskaZatrudnienie Sp. z o.o.'),
  ('CTR-007','Sipho Dlamini','Support Specialist','South Africa','ZAR',38000,'Monthly','2025-08-01','2026-08-01','Active','Contractor',null),
  ('CTR-008','Jasmine Cruz','Content Designer','Philippines','USD',2400,'Monthly','2026-01-01','2027-01-01','Active','EOR Employee',null)
on conflict (code) do nothing;

insert into public.contractor_pay_runs (run_code, period, run_date, total_zar, status) values
  ('CPR-2026-04','April 2026','2026-04-25',1183000,'Paid'),
  ('CPR-2026-03','March 2026','2026-03-20',1054000,'Paid')
on conflict (run_code) do nothing;
