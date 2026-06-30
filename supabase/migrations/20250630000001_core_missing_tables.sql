-- ============================================================
-- NexCore Sprint 2 — Missing tables
-- Apply via: Supabase Dashboard → SQL Editor → New Query
-- Or: supabase db push  (after: supabase link --project-ref anncqmypbgxuzkvxpptk)
-- ============================================================

-- ─── employees ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.employees (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  emp_id        text        UNIQUE NOT NULL,
  first_name    text        NOT NULL,
  surname       text        NOT NULL,
  department    text,
  job_title     text,
  basic_salary  numeric(12,2) NOT NULL DEFAULT 0,
  tax_number    text,
  id_number     text,        -- stored encrypted via pgcrypto in production
  bank_name     text,
  bank_account  text,        -- stored encrypted via pgcrypto in production
  bank_branch   text,
  start_date    date,
  leave_balance numeric(5,1) NOT NULL DEFAULT 21,
  status        text        NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active','inactive','terminated')),
  entity_id     uuid        REFERENCES public.entities(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;

CREATE POLICY "HR, Admin, CFO, Manager read employees"
  ON public.employees FOR SELECT
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','cfo','hr_manager','manager'));

CREATE POLICY "Admin and HR insert employees"
  ON public.employees FOR INSERT
  WITH CHECK ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
              IN ('admin','hr_manager'));

CREATE POLICY "Admin and HR update employees"
  ON public.employees FOR UPDATE
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','hr_manager'));

CREATE INDEX IF NOT EXISTS idx_employees_status ON public.employees(status);
CREATE INDEX IF NOT EXISTS idx_employees_dept   ON public.employees(department);

-- ─── budget_lines ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.budget_lines (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  fiscal_year     text        NOT NULL DEFAULT '2025',
  department      text        NOT NULL,
  category        text,
  budget_amount   numeric(15,2) NOT NULL DEFAULT 0,
  actual_spent    numeric(15,2) NOT NULL DEFAULT 0,
  committed       numeric(15,2) NOT NULL DEFAULT 0,
  restricted      boolean     NOT NULL DEFAULT false,
  entity_id       uuid        REFERENCES public.entities(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.budget_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Finance roles read budget"
  ON public.budget_lines FOR SELECT
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','cfo','manager'));

CREATE POLICY "Admin and CFO manage budget"
  ON public.budget_lines FOR ALL
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','cfo'));

CREATE INDEX IF NOT EXISTS idx_budget_lines_fy ON public.budget_lines(fiscal_year, department);

-- ─── audit_log ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.audit_log (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at  timestamptz NOT NULL DEFAULT now(),
  user_id     uuid        REFERENCES auth.users(id),
  user_name   text,
  module      text        NOT NULL,
  action      text        NOT NULL,
  record_ref  text,
  amount      numeric(15,2),
  severity    text        NOT NULL DEFAULT 'info'
                            CHECK (severity IN ('info','warning','critical')),
  meta        jsonb,
  checksum    text        -- SHA-256 of key fields, verified on read
);
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admin and CFO read audit log"
  ON public.audit_log FOR SELECT
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','cfo'));

-- Helper function: call from any Edge Function to write an audit entry
CREATE OR REPLACE FUNCTION public.audit_write(
  p_module    text,
  p_action    text,
  p_ref       text    DEFAULT NULL,
  p_amount    numeric DEFAULT NULL,
  p_severity  text    DEFAULT 'info',
  p_meta      jsonb   DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.audit_log
    (user_id, user_name, module, action, record_ref, amount, severity, meta)
  VALUES (
    auth.uid(),
    (SELECT full_name FROM public.user_profiles WHERE id = auth.uid()),
    p_module, p_action, p_ref, p_amount, p_severity, p_meta
  );
END;
$$;

CREATE INDEX IF NOT EXISTS idx_audit_log_created ON public.audit_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_module  ON public.audit_log(module, action);

-- ─── vendors ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.vendors (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text        NOT NULL,
  registration  text,
  vat_number    text,
  contact_email text,
  contact_phone text,
  address       text,
  rating        numeric(3,1) NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
  status        text        NOT NULL DEFAULT 'active'
                              CHECK (status IN ('active','inactive','blacklisted')),
  category      text,
  payment_terms text        NOT NULL DEFAULT 'NET30',
  entity_id     uuid        REFERENCES public.entities(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.vendors ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Finance and managers read vendors"
  ON public.vendors FOR SELECT
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','cfo','manager','hr_manager'));

CREATE POLICY "Admin and CFO manage vendors"
  ON public.vendors FOR ALL
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','cfo'));

CREATE INDEX IF NOT EXISTS idx_vendors_status ON public.vendors(status);

-- ─── purchase_orders ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.purchase_orders (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  po_number     text        UNIQUE NOT NULL,
  vendor_id     uuid        REFERENCES public.vendors(id),
  requester_id  uuid        REFERENCES auth.users(id),
  approver_id   uuid        REFERENCES auth.users(id),
  total_amount  numeric(15,2) NOT NULL DEFAULT 0,
  status        text        NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft','pending_approval','approved',
                                                'rejected','received','cancelled')),
  description   text,
  due_date      date,
  entity_id     uuid        REFERENCES public.entities(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Requester and managers read POs"
  ON public.purchase_orders FOR SELECT
  USING (requester_id = auth.uid()
    OR (SELECT role FROM public.user_profiles WHERE id = auth.uid())
       IN ('admin','cfo','manager'));

CREATE POLICY "Authenticated users create POs"
  ON public.purchase_orders FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "Managers update POs"
  ON public.purchase_orders FOR UPDATE
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','cfo','manager'));

CREATE INDEX IF NOT EXISTS idx_po_status ON public.purchase_orders(status);
CREATE INDEX IF NOT EXISTS idx_po_vendor ON public.purchase_orders(vendor_id);

-- ─── approvals ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.approvals (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  module          text        NOT NULL,  -- 'leave','po','payroll','expense','claim'
  record_ref      text        NOT NULL,  -- UUID of the item requiring approval
  record_label    text,
  amount          numeric(15,2),
  requester_id    uuid        REFERENCES auth.users(id),
  requester_name  text,
  approver_id     uuid        REFERENCES auth.users(id),
  status          text        NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending','approved','rejected','escalated')),
  notes           text,
  entity_id       uuid        REFERENCES public.entities(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz
);
ALTER TABLE public.approvals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Requester and approvers read approvals"
  ON public.approvals FOR SELECT
  USING (requester_id = auth.uid() OR approver_id = auth.uid()
    OR (SELECT role FROM public.user_profiles WHERE id = auth.uid())
       IN ('admin','cfo','manager'));

CREATE POLICY "Authenticated users create approval requests"
  ON public.approvals FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "Managers resolve approvals"
  ON public.approvals FOR UPDATE
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','cfo','manager'));

-- Enable Realtime so the Approvals widget updates live
ALTER PUBLICATION supabase_realtime ADD TABLE public.approvals;

CREATE INDEX IF NOT EXISTS idx_approvals_status    ON public.approvals(status);
CREATE INDEX IF NOT EXISTS idx_approvals_requester ON public.approvals(requester_id);

-- ─── projects ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.projects (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text        NOT NULL,
  code        text        UNIQUE,
  status      text        NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active','on_hold','completed','cancelled')),
  owner_id    uuid        REFERENCES auth.users(id),
  budget      numeric(15,2) NOT NULL DEFAULT 0,
  spent       numeric(15,2) NOT NULL DEFAULT 0,
  start_date  date,
  end_date    date,
  description text,
  entity_id   uuid        REFERENCES public.entities(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;

CREATE POLICY "All staff read projects"
  ON public.projects FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "Managers create projects"
  ON public.projects FOR INSERT
  WITH CHECK ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
              IN ('admin','manager'));

CREATE POLICY "Managers update projects"
  ON public.projects FOR UPDATE
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','manager'));

CREATE INDEX IF NOT EXISTS idx_projects_status ON public.projects(status);

-- ─── crm_deals ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.crm_deals (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  title         text        NOT NULL,
  company       text,
  contact_name  text,
  contact_email text,
  value         numeric(15,2) NOT NULL DEFAULT 0,
  stage         text        NOT NULL DEFAULT 'prospect'
                              CHECK (stage IN ('prospect','qualified','proposal',
                                               'negotiation','won','lost')),
  probability   integer     NOT NULL DEFAULT 50 CHECK (probability BETWEEN 0 AND 100),
  owner_id      uuid        REFERENCES auth.users(id),
  close_date    date,
  notes         text,
  entity_id     uuid        REFERENCES public.entities(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.crm_deals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Sales and managers read deals"
  ON public.crm_deals FOR SELECT
  USING (owner_id = auth.uid()
    OR (SELECT role FROM public.user_profiles WHERE id = auth.uid())
       IN ('admin','cfo','manager'));

CREATE POLICY "Authenticated users create deals"
  ON public.crm_deals FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "Owner and managers update deals"
  ON public.crm_deals FOR UPDATE
  USING (owner_id = auth.uid()
    OR (SELECT role FROM public.user_profiles WHERE id = auth.uid())
       IN ('admin','manager'));

CREATE INDEX IF NOT EXISTS idx_crm_stage ON public.crm_deals(stage);

-- ─── invoices ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.invoices (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_number  text        UNIQUE NOT NULL,
  vendor_id       uuid        REFERENCES public.vendors(id),
  po_id           uuid        REFERENCES public.purchase_orders(id),
  amount_excl     numeric(15,2) NOT NULL DEFAULT 0,
  vat_amount      numeric(15,2) NOT NULL DEFAULT 0,
  amount_incl     numeric(15,2) GENERATED ALWAYS AS (amount_excl + vat_amount) STORED,
  status          text        NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending','approved','paid','rejected','disputed')),
  due_date        date,
  paid_date       date,
  pdf_url         text,       -- Supabase Storage signed URL
  entity_id       uuid        REFERENCES public.entities(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Finance reads all invoices"
  ON public.invoices FOR SELECT
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','cfo','manager'));

CREATE POLICY "Vendors read their own invoices"
  ON public.invoices FOR SELECT
  USING (vendor_id IN (
    SELECT id FROM public.vendors
    WHERE contact_email = (SELECT email FROM auth.users WHERE id = auth.uid())
  ));

CREATE POLICY "Finance manages invoices"
  ON public.invoices FOR ALL
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','cfo'));

CREATE INDEX IF NOT EXISTS idx_invoices_status ON public.invoices(status);
CREATE INDEX IF NOT EXISTS idx_invoices_vendor ON public.invoices(vendor_id);

-- ─── chat_messages ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.chat_messages (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  channel     text        NOT NULL DEFAULT 'general',
  sender_id   uuid        REFERENCES auth.users(id),
  sender_name text,
  content     text        NOT NULL,
  entity_id   uuid        REFERENCES public.entities(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "All authenticated users read chat"
  ON public.chat_messages FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "Authenticated users post messages"
  ON public.chat_messages FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL AND sender_id = auth.uid());

ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;

CREATE INDEX IF NOT EXISTS idx_chat_channel ON public.chat_messages(channel, created_at DESC);

-- ─── claims ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.claims (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  claimant_id     uuid        REFERENCES auth.users(id),
  claimant_name   text,
  claim_type      text        NOT NULL DEFAULT 'expense',
  description     text        NOT NULL,
  amount          numeric(12,2) NOT NULL DEFAULT 0,
  receipt_url     text,       -- Supabase Storage object path
  status          text        NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending','approved','rejected','paid')),
  submitted_date  date        NOT NULL DEFAULT CURRENT_DATE,
  approved_by     uuid        REFERENCES auth.users(id),
  entity_id       uuid        REFERENCES public.entities(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.claims ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Claimant reads own claims; managers read all"
  ON public.claims FOR SELECT
  USING (claimant_id = auth.uid()
    OR (SELECT role FROM public.user_profiles WHERE id = auth.uid())
       IN ('admin','cfo','manager','hr_manager'));

CREATE POLICY "Authenticated users submit claims"
  ON public.claims FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL AND claimant_id = auth.uid());

CREATE POLICY "Managers process claims"
  ON public.claims FOR UPDATE
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
         IN ('admin','cfo','manager'));

CREATE INDEX IF NOT EXISTS idx_claims_claimant ON public.claims(claimant_id);
CREATE INDEX IF NOT EXISTS idx_claims_status   ON public.claims(status);

-- ─── assets (fixed asset register) ───────────────────────────
CREATE TABLE IF NOT EXISTS public.assets (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_code          text        UNIQUE NOT NULL,
  name                text        NOT NULL,
  category            text,
  location            text,
  assigned_to         uuid        REFERENCES auth.users(id),
  purchase_date       date,
  purchase_value      numeric(12,2) NOT NULL DEFAULT 0,
  current_value       numeric(12,2) NOT NULL DEFAULT 0,
  depreciation_rate   numeric(5,2) NOT NULL DEFAULT 20,  -- % per year straight-line
  status              text        NOT NULL DEFAULT 'active'
                                    CHECK (status IN ('active','disposed','stolen','under_repair')),
  entity_id           uuid        REFERENCES public.entities(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.assets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "All staff read assets" ON public.assets FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "Admin and CFO manage assets"
  ON public.assets FOR ALL
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid()) IN ('admin','cfo'));

CREATE INDEX IF NOT EXISTS idx_assets_status ON public.assets(status);

-- ─── contracts (Vault / ESS document signing) ─────────────────
CREATE TABLE IF NOT EXISTS public.contracts (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id     uuid        REFERENCES auth.users(id),
  document_type   text        NOT NULL,  -- 'employment_contract','nda','offer_letter','policy_ack'
  title           text        NOT NULL,
  storage_path    text,                  -- Supabase Storage object path (private bucket)
  signed_at       timestamptz,
  signed_by       uuid        REFERENCES auth.users(id),
  expires_at      timestamptz,
  status          text        NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending','signed','expired','revoked')),
  entity_id       uuid        REFERENCES public.entities(id),
  created_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.contracts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Employee reads own contracts; HR reads all"
  ON public.contracts FOR SELECT
  USING (employee_id = auth.uid()
    OR (SELECT role FROM public.user_profiles WHERE id = auth.uid())
       IN ('admin','hr_manager'));

CREATE POLICY "HR creates contracts"
  ON public.contracts FOR INSERT
  WITH CHECK ((SELECT role FROM public.user_profiles WHERE id = auth.uid())
              IN ('admin','hr_manager'));

CREATE POLICY "Employee or HR can sign/update contracts"
  ON public.contracts FOR UPDATE
  USING (employee_id = auth.uid()
    OR (SELECT role FROM public.user_profiles WHERE id = auth.uid())
       IN ('admin','hr_manager'));

CREATE INDEX IF NOT EXISTS idx_contracts_employee ON public.contracts(employee_id);
CREATE INDEX IF NOT EXISTS idx_contracts_status   ON public.contracts(status);
