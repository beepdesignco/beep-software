-- Phase 0, step 17 — U-Freight Phase 5 Part 2 follow-up.
--
-- Persist reconciliation metadata on invoice_line_items so credits
-- survive a page reload. Without this, _reconType is local-only and
-- credit rows revert to regular line items after refresh.
--
-- Idempotent.

begin;

alter table invoice_line_items
  add column if not exists recon_type    text,
  add column if not exists settlement_id uuid references freight_settlements(id) on delete set null;

create index if not exists idx_invoice_line_items_settlement
  on invoice_line_items(settlement_id)
  where settlement_id is not null;

commit;

select column_name, data_type from information_schema.columns
  where table_name = 'invoice_line_items'
    and column_name in ('recon_type', 'settlement_id');
