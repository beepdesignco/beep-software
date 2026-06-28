-- Phase 0, step 40 — invoice_freight_allocations.proposal_component_id.
--
-- When a constructed item is billed via multiple component lines on an
-- invoice (e.g., FLW Sectional split into Fabric + Frame line items),
-- each line currently produces an allocation row keyed only on the
-- parent proposal_item_id — so the Budget → Freight modal aggregates
-- all components into a single parent row. Adding the optional
-- component FK lets the modal render one row per billed line and show
-- "Item · Component" labels.
--
-- Nullable: item-level lines (whole-item billing, readymade items) keep
-- proposal_component_id null and behave exactly as before.
--
-- Idempotent.

begin;

alter table invoice_freight_allocations
  add column if not exists proposal_component_id uuid
    references proposal_components(id) on delete set null;

create index if not exists idx_invoice_freight_allocations_component
  on invoice_freight_allocations(proposal_component_id)
  where deleted_at is null;

commit;

-- Verify
select column_name, data_type, is_nullable
  from information_schema.columns
 where table_name = 'invoice_freight_allocations'
   and column_name = 'proposal_component_id';

select indexname from pg_indexes
 where tablename = 'invoice_freight_allocations'
   and indexname = 'idx_invoice_freight_allocations_component';
