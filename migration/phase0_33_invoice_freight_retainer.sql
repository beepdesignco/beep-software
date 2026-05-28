-- Phase 0, step 33 — freight_retainer on invoices.
--
-- "Bill Freight as Retainer" on the invoice builder lets the user apply a
-- single % across a chosen set of proposal items at invoice time. Previously
-- we wrote this back to the proposal items' freight_charges rows, which
-- mutated the proposal (and bumped its history). That's wrong: the proposal
-- is the quote — the invoice is the bill. They should be tracked separately
-- so PM / financial reporting can compare proposed vs charged vs actual.
--
-- This column persists the invoice-side retainer override:
--   { "pct": <number>, "item_ids": [<proposal_item_id>, ...] }
--
-- At invoice render time, recalcInvFreight uses these item ids to compute
-- (item subtotal × pct/100) for each covered item instead of reading the
-- proposal's freight_charges. Items not in item_ids keep their proposal
-- freight as-is. The pct is the as-billed-to-client percent (no markup).
--
-- NULL = no retainer override; behave as before (sum from freight_charges).
--
-- Idempotent.

begin;

alter table invoices
  add column if not exists freight_retainer jsonb;

commit;

-- Verify
select column_name, data_type, is_nullable from information_schema.columns
  where table_name = 'invoices' and column_name = 'freight_retainer';
