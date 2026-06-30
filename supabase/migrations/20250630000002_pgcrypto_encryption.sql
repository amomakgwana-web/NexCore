-- ============================================================
-- NexCore Sprint 6 — Field-level encryption via pgcrypto
-- Apply AFTER 20250630000001_core_missing_tables.sql
-- ============================================================

-- Enable pgcrypto extension (idempotent)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ─── Encryption helper functions ─────────────────────────────
-- encrypt_field: takes plaintext + key, returns hex-encoded AES-256-CBC ciphertext
CREATE OR REPLACE FUNCTION public.encrypt_field(plaintext text, enc_key text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF plaintext IS NULL OR plaintext = '' THEN RETURN NULL; END IF;
  RETURN encode(
    pgp_sym_encrypt(plaintext, enc_key, 'compress-algo=0, cipher-algo=aes256'),
    'base64'
  );
END;
$$;

-- decrypt_field: decrypts what encrypt_field produced
CREATE OR REPLACE FUNCTION public.decrypt_field(ciphertext text, enc_key text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF ciphertext IS NULL OR ciphertext = '' THEN RETURN NULL; END IF;
  RETURN pgp_sym_decrypt(decode(ciphertext, 'base64'), enc_key);
EXCEPTION WHEN OTHERS THEN RETURN NULL; -- wrong key or corrupted data
END;
$$;

-- Restrict direct function execution to service_role only
REVOKE ALL ON FUNCTION public.encrypt_field(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.decrypt_field(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.encrypt_field(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.decrypt_field(text, text) TO service_role;

-- ─── Add encrypted columns to employees ──────────────────────
-- We store a *_enc (encrypted) column alongside the plaintext column.
-- In production: write only to *_enc, read via decrypt_field in Edge Functions.
-- The plaintext column is kept NULL once encryption is enabled.
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS id_number_enc  text,
  ADD COLUMN IF NOT EXISTS bank_account_enc text;

-- ─── Audit log: record encryption key rotation events ─────────
-- (actual key stored in Supabase Vault / env secret — NOT in this file)
CREATE TABLE IF NOT EXISTS public.key_rotations (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  rotated_at  timestamptz NOT NULL DEFAULT now(),
  rotated_by  uuid        REFERENCES auth.users(id),
  description text
);
ALTER TABLE public.key_rotations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admin only reads key rotations"
  ON public.key_rotations FOR SELECT
  USING ((SELECT role FROM public.user_profiles WHERE id = auth.uid()) = 'admin');

CREATE POLICY "Admin only inserts key rotations"
  ON public.key_rotations FOR INSERT
  WITH CHECK ((SELECT role FROM public.user_profiles WHERE id = auth.uid()) = 'admin');

-- ─── Usage notes ─────────────────────────────────────────────
-- Store the encryption key in: Supabase → Project Settings → Vault → Secrets
--   Key name: NEXCORE_FIELD_ENC_KEY
-- In Edge Functions, read via: Deno.env.get('NEXCORE_FIELD_ENC_KEY')
-- To encrypt on write:
--   UPDATE employees SET id_number_enc = encrypt_field(id_number, current_setting('app.enc_key')),
--                        id_number = NULL WHERE id = $1;
-- To decrypt on read (service_role only):
--   SELECT decrypt_field(id_number_enc, current_setting('app.enc_key')) AS id_number FROM employees;
