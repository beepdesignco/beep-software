-- Phase 0, step 32 — receipt_path on invoice_payments.
--
-- Mobile lets the user attach a photo of a check / receipt when recording
-- an invoice payment. The photo lives in Supabase Storage; we store its
-- path on the payment row so the web (and future mobile builds) can
-- surface it. Web currently has no UI to capture one but will round-trip
-- the column so mobile-written data survives a web edit.
--
-- Convention: `{studio_id}/payments/{payment_id}/{uuid}.{ext}` in the
-- `files` bucket (same bucket as expense receipts).
--
-- Idempotent.

begin;

alter table invoice_payments
  add column if not exists receipt_path text;

commit;

-- Verify
select column_name, data_type, is_nullable from information_schema.columns
  where table_name = 'invoice_payments' and column_name = 'receipt_path';
