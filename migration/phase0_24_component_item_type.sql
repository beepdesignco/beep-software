-- Phase 0, step 24 — item_type_id on proposal_components.
--
-- Components can carry their own item-type tag, independent of the
-- parent constructed item's type. Drives list-export filtering: a
-- "Furniture" filter on a kitchen island can pull only the furniture-
-- type components instead of every fabric / hardware piece.
--
-- Idempotent.

begin;

alter table proposal_components
  add column if not exists item_type_id uuid references item_types(id) on delete set null;

create index if not exists idx_proposal_components_item_type
  on proposal_components(item_type_id) where deleted_at is null;

commit;

select column_name, data_type from information_schema.columns
  where table_name = 'proposal_components' and column_name = 'item_type_id';
