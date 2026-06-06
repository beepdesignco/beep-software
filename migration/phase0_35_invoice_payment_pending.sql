-- Phase 0, step 35 — pending flag on invoice_payments.
--
-- ACH payments (via Stripe Checkout + Financial Connections / Plaid) take
-- 3-5 business days to actually settle. Previously the webhook recorded
-- the payment row at submission time with the current date — which over-
-- reported sales tax in the submission month (Baylor files cash basis,
-- so tax is recognized when funds are RECEIVED, not when the client
-- clicked Pay).
--
-- New flow:
--   * checkout.session.completed (ACH unpaid):
--       INSERT row, pending = true, date = submission date
--       Invoice stays at 'sent'; payment shows in UI with Pending badge
--   * checkout.session.async_payment_succeeded:
--       UPDATE pending = false, date = settlement date (today)
--       Recompute invoice status (paid/partial); PM cascades fire here
--   * checkout.session.async_payment_failed:
--       DELETE the row; invoice falls back to 'sent'
--
-- Card payments always insert with pending = false (instant settlement).
-- Manual payment entries (Record Payment in BEEP HQ) default to pending
-- = false because Baylor enters them when he sees the funds.
--
-- Tax report (buildSalesTaxReport) filters out pending=true rows so
-- the monthly tax filing reflects only actually-received funds. Invoice
-- builder Paid/Outstanding totals also exclude pending.
--
-- Idempotent.

begin;

alter table invoice_payments
  add column if not exists pending boolean not null default false;

create index if not exists invoice_payments_pending_idx
  on invoice_payments (invoice_id) where pending = true;

commit;

-- Verify
select column_name, data_type, column_default, is_nullable
  from information_schema.columns
  where table_name = 'invoice_payments' and column_name = 'pending';
