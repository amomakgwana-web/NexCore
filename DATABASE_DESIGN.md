# Database Design — Gap Analysis Against the Solution's User Flows

This maps every major user flow in MORR ERP to the Supabase schema as it
stands today, and states plainly what is missing. The schema currently has
38 tables; the biggest structural finding is that roughly **half of the
app's modules have no relational tables at all** — their state persists as
one JSON blob per module in `nx_module_state` (the NXDB layer). That is
fine for demo persistence, but it means no queries, no joins, no RLS
per-row security, and no reporting on those modules from the database side.

## What already works (verified relationships)

| Flow | Tables | State |
|---|---|---|
| Identity & access | `user_profiles` → `auth.users`, `entities`; `login_attempts` + lockout RPCs; `otp_codes` | Solid. Roles enum, MFA flag, is_active, brute-force throttling in DB. |
| Leave (two-stage) | `leave_requests` (+`manager_approved` enum value, medical columns) → `user_profiles`; `leave_balances` | Solid after this session's migrations. |
| Payroll core | `payroll_employees`/`payroll_deductions`/`payroll_runs` → `user_profiles` | Solid for calc + run history. |
| Procurement | `purchase_orders` → `vendors`, `entities`, requestor/approver; now → `budget_lines` | Solid. |
| Billing (AR) | `invoices` → `vendors`, `entities`; recurring schedule in `nx_module_state` | Works; see gap #4. |
| Projects | `projects` → `project_tasks`; tasks now → assignee `user_profiles` | Solid. |
| CRM | `crm_deals` (+ client-side `CRM_DEAL_META` for comments/files/tags) | Works; see gap #5. |
| Audit | `audit_log` → `auth.users`, realtime-enabled | Solid. |
| E-signature / onboarding | `nx_sign_requests` (+ `personal_details` jsonb, NDA flow), `contracts` | Solid. |
| GL journals | `nx_journals` (jsonb lines) + **new** `chart_of_accounts` | Anchored now; see gap #2. |

Added in migration `20260709000002_link_codependent_tables`:
`employees.user_id→user_profiles` (HR↔identity), `claims.manager_id` +
`claims.cfo_approved_by`, `nx_claims.manager_id`, `nx_payments.invoice_id→invoices`,
`purchase_orders.budget_line_id→budget_lines`, `project_tasks.assignee_id`,
and the `chart_of_accounts` table (16 seeded accounts, RLS: read-all /
write admin+cfo).

## What is missing, per user flow

### 1. Modules with no tables at all (highest impact)
These run entirely client-side, persisted only as JSON in `nx_module_state`:
**Fleet** (vehicles, fuel log, service history, fuel-sensor devices, driver
budgets), **Quotes**, **Contractors** (profiles, pay runs, timesheets),
**Inventory/Stock** (SKUs, movements, reorders), **Fixed-asset register**
(the `assets` table exists but the app's register with depreciation/history
runs client-side), **Boards/Kanban**, **Risk register**, **Card
transactions**, **Bank statement feed**, **Budget departments** (the app's
richer dept model vs the flat `budget_lines`), **IAM permission matrix**,
**SARS submissions history**, **Cash-flow period history**.

For each of these, the use case that breaks without a table: any query
across records ("all vehicles overdue for service", "quotes expiring this
month"), per-row security (a vendor must not read other vendors' quotes),
and multi-user concurrent edits (last-writer-wins on a JSON blob loses data).

Proposed order of extraction (by business risk): `quotes` →
`card_transactions` → `bank_statement_lines` → `fleet_vehicles` +
`fuel_log` → `stock_items` + `stock_movements` → `contractors` +
`contractor_pay_runs` → the rest.

### 2. GL integrity
`nx_journals.lines` is free jsonb — nothing stops a line referencing a
nonexistent account code, and balance (debit=credit) is enforced only in
application code (frontend + accounting-service). Missing:
- a `journal_lines` child table (`journal_id`, `account_code →
  chart_of_accounts`, `debit`, `credit`) so referential integrity is real, and
- a DB-level check (trigger or deferred constraint) that a journal balances.

### 3. Payroll period control
`payroll_runs` stores month/year per row but there is no `payroll_periods`
table with an open/locked status. Use case that breaks: nothing in the DB
prevents processing the same employee twice for May 2026, or posting into a
closed month. Needs `payroll_periods (id, month, year, status
open|approved|locked, manager_approved_by, cfo_approved_by)` — this also
gives the attendance-reconciliation approval gate (currently client-side
state) a real home.

### 4. Recurring billing schedules
Stored as JSON under `nx_module_state['billing-recurring']`. Works, but a
`recurring_schedules` table (`invoice_id FK`, `frequency`, `next_date`,
`active`) would let the DB itself (pg_cron) generate follow-on invoices
instead of relying on a client/service being online.

### 5. CRM collaboration data
Deal comments, attachments, tags and member assignments live in the
client-side `CRM_DEAL_META` blob. Missing `deal_comments`,
`deal_attachments`, `deal_members` child tables — required before two
users can safely work the same deal.

### 6. Departments & org structure
`employees.department` and `budget_lines.department` are free text — no
`departments` table, so the department drill-throughs join on string
equality. A `departments (id, name, entity_id, manager_id)` table with FKs
from employees/budget_lines/claims makes org reporting reliable, and gives
"reassign manager" a single place to act.

### 7. Duplicate employee models
Three overlapping employee representations exist: `employees` (HR master),
`payroll_employees` (keyed on user_profiles), and `nx_employees` (demo
register). Now that `employees.user_id` exists, the target design is:
`user_profiles` = identity, `employees` = HR record (FK to identity),
`payroll_employees` = payroll config (FK to identity) — and `nx_employees`
retired once the frontend reads from `employees`.

### 8. Notifications/email linkage
`nx_email_log` has no FK to what triggered the email (claim, leave request,
invoice, policy broadcast). A polymorphic `(source_table, source_id)` pair
or per-type nullable FKs would make "show me every email about claim X"
answerable.

## RLS note
Every table has RLS enabled. The new `chart_of_accounts` follows the
read-all/write-finance pattern. When the module tables in gap #1 are
created, each needs the same treatment — especially `quotes` (vendor
isolation) and `card_transactions` (finance-only).

**Security advisor sweep (`20260720000001`–`3`)**: `deal_comments` /
`deal_attachments` / `deal_members` had `for all using (true) with check
(true)` policies — any authenticated user (any role) could read, edit, or
delete any other user's rows on any deal, and INSERT didn't check identity,
so a user could post a comment "as" someone else. Tightened to
SELECT/INSERT-own for any authenticated user, UPDATE/DELETE restricted to
the row's own author/uploader/member or an admin/cfo/manager/hr_manager
override. Separately, `audit_write`, `nx_check_rate`, and `rls_auto_enable`
were still callable by `anon` over PostgREST RPC despite two earlier
migrations (`20250704000001`, `20250705000001`) trying to revoke it —
those revoked from `anon`/`authenticated` specifically, but the functions
still granted `EXECUTE` to `PUBLIC` from creation time, and a named-role
revoke is a no-op against a standing `PUBLIC` grant. Revoked from `PUBLIC`
directly and re-granted to `service_role` only. None of the three are ever
called from the client (`writeAudit()` inserts into `audit_log` directly
under its own policy instead), so this closes real excess privilege with
no functional change. `check_login_lockout`/`record_login_attempt` remain
callable by `anon` — that's intentional, both run during the login flow
itself before a session exists.

**On the Supabase anon key living in the client source**: this is not a
gap. `SUPABASE_URL`/`SUPABASE_ANON_KEY` are necessarily public in any
browser-only Supabase app — same as a Firebase config object — and the
password lock on Settings → Supabase Configuration (see `dbLockGateHTML`)
is a UI convenience, not a security boundary; it doesn't and can't make an
already-public key secret. The actual boundary is RLS, which is what this
sweep hardens. The one thing that must never ship client-side is the
*service role* key, and it doesn't — the Settings panel's "Service Role
Key" field is a static placeholder string, and the real key only exists
server-side in the microservices' environment variables
(`services/_shared/serviceFactory.js` reads
`SUPABASE_SERVICE_ROLE_KEY` from `process.env`).

## Migration status
1. ~~`journal_lines` + balance trigger (gap 2)~~ — **DONE**
   (`20260709000003`): 17 lines backfilled from jsonb, unbalanced-journal
   insert verified rejected by the DB, balanced insert verified accepted.
2. ~~`payroll_periods` (gap 3)~~ — **DONE** (`20260709000004`): Feb–Apr
   2026 locked, May 2026 open; run into a locked period verified rejected;
   unique index prevents duplicate runs per employee+period.
3. ~~`quotes` + `recurring_schedules` (gaps 1, 4)~~ — **DONE**
   (`20260709000005`): 5 quotes seeded on the May-2026 timeline;
   billing-service rewritten to use recurring_schedules rows (upsert with a
   unique invoice constraint) instead of the nx_module_state JSON blob.
4. ~~`departments` + backfill (gap 6)~~ — **DONE** (`20260709000006`):
   10 departments seeded, FK columns added to employees/budget_lines
   alongside the legacy text.
5. ~~CRM child tables (gap 5)~~ — **DONE** (`20260709000006`):
   deal_comments / deal_attachments / deal_members with RLS.
6. ~~Fleet/stock/contractors extraction (gap 1 remainder)~~ — **DONE**
   (`20260710000001`): fleet_vehicles (4) + fuel_log (5), stock_items (6) +
   stock_movements (13), contractors (8) + contractor_pay_runs (2) +
   contractor_pay_lines, all with RLS, seeded on the May-2026 timeline.
   Also fixed a pre-existing seed bug surfaced by the extraction (CTR-005
   had end_date before start_date; the table now has a CHECK preventing it).
7. ~~Frontend rewiring~~ — **DONE** for the extracted modules: the app now
   loads quotes, fleet, fuel log, stock, contractors, pay runs and the
   chart of accounts from their tables at login (loadQuotesFromDB /
   loadFleetFromDB / loadStockFromDB / loadContractorsFromDB /
   loadCOAFromDB), adapting rows into the existing render shapes and
   falling back to the built-in demo seed when there is no session or a
   table is empty — the same convention the app already used for invoices
   and CRM deals. Still client-state only: boards/kanban, risk register,
   IAM matrix, card transactions, bank feed, SARS submission history
   (tables exist for none of these yet — next candidates).
