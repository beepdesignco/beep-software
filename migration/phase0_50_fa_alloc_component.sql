-- Split freight actuals: allow each allocation slice to target a COMPONENT
-- of a constructed item, not just the item. Mirrors phase0_40 which added
-- the same granularity to invoice_freight_allocations (collected side).
-- Slices still roll up to the parent item for item-level reconciliation;
-- the componentId powers component sub-rows in the Budget → Freight
-- invoice modal and component-accurate attribution.

begin;

alter table freight_actual_allocations
  add column if not exists proposal_component_id uuid references proposal_components(id) on delete set null;

create index if not exists freight_actual_allocations_component_idx
  on freight_actual_allocations(proposal_component_id) where proposal_component_id is not null;

commit;

select column_name from information_schema.columns
  where table_name = 'freight_actual_allocations' and column_name = 'proposal_component_id';
