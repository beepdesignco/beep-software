-- Phase 0, step 36 — small PM-side adds on proposal_items:
--   cost_actual_payment_method — which card/method was used when paying
--                                 the vendor. Same dropdown as expense
--                                 payment method (sources S.paymentCards).
--   vendor_order_number        — vendor's order/PO reference number,
--                                 free text. Surfaced on PM item detail.
--
-- Both are §12 sub-items from the 2026-06-13 spec. Stored as plain text;
-- the web app reads/writes via savePMField (generic field setter).
--
-- Idempotent.

begin;

alter table proposal_items
  add column if not exists cost_actual_payment_method text,
  add column if not exists vendor_order_number        text;

commit;

-- Verify
select column_name, data_type
  from information_schema.columns
  where table_name = 'proposal_items'
    and column_name in ('cost_actual_payment_method', 'vendor_order_number');
