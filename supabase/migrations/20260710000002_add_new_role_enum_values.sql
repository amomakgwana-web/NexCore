-- New functional roles for the role->module assignment engine:
-- Driver, Office Admin, IT Team, PMO, Accountant. Enum-value additions
-- only (no references to the new values in this migration — Postgres
-- requires the ADD VALUE to commit before first use).
alter type public.nexcore_role add value if not exists 'driver';
alter type public.nexcore_role add value if not exists 'office_admin';
alter type public.nexcore_role add value if not exists 'it_team';
alter type public.nexcore_role add value if not exists 'pmo';
alter type public.nexcore_role add value if not exists 'accountant';
