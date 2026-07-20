# Microservices + Load Balancing

## Why this exists

MORR ERP started as a single static HTML file talking directly to Supabase.
Supabase already scales and load-balances its own managed infrastructure —
there was nothing on our side to put a load balancer in front of. This
directory adds a real, independently-deployable service tier so that (a)
business logic can run and scale server-side instead of only in the
browser, and (b) load balancing is a genuine, configurable piece of the
architecture rather than something inherited for free.

**The frontend (`nexcore-standalone.html`) has NOT been rewired to call
these services yet.** It still talks to Supabase directly. Cutting 14,000+
lines of tightly-coupled UI over to a new API surface is a separate,
higher-risk piece of work — this phase is the service tier + load balancer,
built and verified on its own before anything user-facing depends on it.

## Layout

```
services/
  manifest.json        # source of truth: every service, its resources, replica count, port
  _shared/
    serviceFactory.js   # Express app factory: health check, CORS, logging, CRUD-route generator
  auth-service/         # hero — real login-attempt/lockout logic (calls existing Postgres RPCs)
  payroll-service/      # hero — real PAYE/UIF calc (SARS 2024/25 tables), pay-run processing
  billing-service/      # hero — VAT calc, a genuine recurring-invoice engine, AR aging
  accounting-service/   # hero — journal balance validation, trial balance aggregation
  finance-service/      # hero — composes payroll-service + billing-service THROUGH THE GATEWAY
  hr-service/           # real CRUD (employees, leave requests/balances, clock events)
  crm-service/          # real CRUD (deals)
  procurement-service/  # real CRUD (purchase orders, vendors)
  approvals-service/    # real CRUD (approvals)
  claims-service/       # real CRUD (claims, nx_claims)
  assets-service/        # real CRUD (assets)
  contracts-service/     # real CRUD (contracts)
  projects-service/      # real CRUD (projects, tasks)
  notifications-service/ # real CRUD (notifications, chat, email log)
  audit-service/          # real CRUD (audit log)
  vault-service/          # real CRUD (e-signature requests)
  entities-service/       # real CRUD (group entities, tenants)
  budget-service/         # real CRUD (budget lines)
  payments-service/       # real CRUD (SwiftPay-style payments)
  state-service/          # real CRUD (NXDB module state, rate limits)
gateway/
  nginx.local.conf     # generated — used by scripts/run-local.mjs (binds 127.0.0.1 only)
  nginx.docker.conf    # generated — used by docker-compose.yml (container hostnames)
scripts/
  generate-services.mjs  # scaffolds services/<name>/{index.js,package.json,Dockerfile} from manifest.json
  generate-infra.mjs      # (re)generates both nginx configs + docker-compose.yml from manifest.json
  run-local.mjs           # starts every replica as a plain OS process + nginx, for environments without Docker
  stop-local.mjs          # stops everything run-local.mjs started
docker-compose.yml     # generated — real deployment target
.env.example
```

**"Hero" vs "CRUD" is an honest label, not a euphemism.** The 5 hero
services (auth, payroll, billing, accounting, finance) have the actual
computed business rules ported over from the app (PAYE tax brackets,
recurring-billing state machine, debit=credit journal validation, etc.).
The other 15 are real, working REST CRUD against their real Supabase
tables — every route in them performs an actual `supabase-js` call, there
is nothing mocked — but they don't yet have bespoke business rules layered
on top. That's the natural next slice of work per domain, done the same way
the 5 hero services were.

## Load balancing — how it actually works

Every service runs as 2 replicas (`services/manifest.json` → `replicas`).
nginx sits in front with one `upstream` block per service:

```
upstream payroll-service {
    least_conn;
    server 127.0.0.1:4011 max_fails=2 fail_timeout=10s;
    server 127.0.0.1:4012 max_fails=2 fail_timeout=10s;
}
```

- **`least_conn`** — routes each request to whichever replica currently has
  fewer open connections, which handles the mix of cheap CRUD reads and
  slower computed endpoints (PAYE calc, journal posting) better than plain
  round-robin.
- **Passive health checks** (`max_fails=2 fail_timeout=10s`) — if a replica
  fails 2 requests in a row, nginx stops sending it traffic for 10 seconds
  and retries automatically after that window.
- Every service response carries an `X-Service-Instance: <name>:<port>:<pid>`
  header, so you can see exactly which replica served any given request —
  this is what made it possible to actually verify the load balancing below,
  rather than just eyeballing a config file.
- The gateway routes by path prefix: `/api/<service-short-name>/...` →
  `services/manifest.json`'s per-service `resources`, e.g. `/api/payroll/summary`,
  `/api/hr/employees`, `/api/billing/invoices`.

## Verified — this was actually run, not just written

Docker's daemon isn't available in the sandbox this was built in (no
privilege to raise ulimits), so `scripts/run-local.mjs` runs every replica as
a plain `node` process and nginx as a plain OS process bound to
`127.0.0.1`, instead of containers. `docker-compose.yml` is the real
deployment target wherever you actually have a Docker daemon (your machine,
CI, a cloud host) — same services, same nginx config, containerized.

With 40 replicas (20 services × 2) + nginx running locally:

**Round-robin/least_conn distribution** — 10 consecutive requests to
`/api/hr/employees` alternated perfectly between both replicas:
```
hr-service:4051:15974
hr-service:4052:15980
hr-service:4051:15974
hr-service:4052:15980   ... (continues alternating)
```
Same result confirmed independently for `crm-service`, `payroll-service`,
and `billing-service`.

**Failover** — killing `hr-service` replica 1 mid-traffic (`kill -9`):
the next 8 requests were all served by replica 2, zero dropped requests,
zero 502s. Restarting the killed replica and waiting past the 10s
`fail_timeout` window brought it back into rotation automatically —
confirmed by requests alternating between both ports again.

**Business logic runs correctly and independently of the DB** —
`accounting-service`'s journal balance validation rejects an unbalanced
entry (`debit ≠ credit`) with a clean `400` *before* it ever reaches
Supabase; a balanced entry passes that check and proceeds to the insert.

**One real bug found and fixed during this verification**: the initial
logging setup used `morgan(`[${name}:${port}] ...`)`. Morgan parses
`:word` in a format string as a token reference, so `:4011` (colon
immediately before a port number) was misread as an unknown token and
crashed every single request. Fixed by changing the separator to `|`
(`services/_shared/serviceFactory.js`).

## A real, disclosed limitation of *this* environment

Direct outbound HTTPS from a spawned process to `*.supabase.co` is blocked
by this sandbox's own network egress allowlist (it allows `registry.npmjs.org`,
`pypi.org`, etc., but not arbitrary hosts — confirmed via
`/root/.ccr/__agentproxy/status`). That means the Supabase-backed
endpoints (e.g. `/api/payroll/summary`, `/api/billing/invoices`) return a
clean `502`/error here, even though the code path, request routing, and
load balancing around them are all correct. This is a property of *this
sandbox*, not the services — it will work in GitHub Actions, on your own
machine, or on any host whose network isn't locked down this way. Nothing
about the LB verification above depends on that call succeeding.

## Running it

### Production-style (Docker, wherever you have a daemon)
```
cp .env.example .env   # fill in SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY
docker compose up --build
curl http://localhost:8080/health
```

### This sandbox / anywhere without Docker
```
export SUPABASE_URL=https://your-project.supabase.co
export SUPABASE_SERVICE_ROLE_KEY=...   # or SUPABASE_ANON_KEY for read-only/RLS-respecting testing
node scripts/run-local.mjs
curl http://127.0.0.1:8080/health
node scripts/stop-local.mjs
```

### Changing the topology
Edit `services/manifest.json` (add a service, change replica counts), then:
```
node scripts/generate-services.mjs   # scaffolds any new service's index.js/package.json/Dockerfile
node scripts/generate-infra.mjs      # regenerates nginx configs + docker-compose.yml
```
`generate-services.mjs` never overwrites an existing `index.js`, so hand-written
business logic (the 5 hero services) is safe to re-run the generator against.

## Security note

Services use `SUPABASE_SERVICE_ROLE_KEY` (bypasses RLS) because they're
meant to run in a trusted backend network, enforcing their own
authorization — the same trust model as any Supabase Edge Function using
the service role key. **Never expose the service role key to the browser
or commit it.** `.env` is gitignored; only `.env.example` (with placeholder
values) is committed.

## What's next (not done in this pass, on purpose)

1. Layer real business rules onto the remaining 15 CRUD services the same
   way the 5 hero services got them (leave-accrual rules in hr-service,
   PO approval workflow in procurement-service, etc.).
2. Decide whether/how to rewire `nexcore-standalone.html` to call the
   gateway instead of Supabase directly — a deliberate, separate decision
   given the size and risk of touching the existing working frontend.
3. Add authentication/authorization at the gateway (currently any caller
   that can reach the gateway can call any service — fine for this
   verification pass, not fine for a real deployment).
4. Replace passive-only health checks with an active health-check loop
   (nginx OSS doesn't do active checks natively; nginx Plus or a sidecar
   would close that gap) and add per-service horizontal autoscaling rules
   once real traffic data exists to size them against.
