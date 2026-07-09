-- Onboarding e-signature requests now also collect personal details (ID
-- number, physical address) and NDA acknowledgment directly from the new
-- employee, not just a contract signature. Stored alongside the existing
-- signature/signed_at columns on the same request row.
alter table public.nx_sign_requests
  add column if not exists personal_details jsonb;
