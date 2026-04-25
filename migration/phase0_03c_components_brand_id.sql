-- Phase 0, step 3c — brand_id on proposal_components.
--
-- Constructed items hold their vendor/contact/brand info per-component
-- (each component may come from a different vendor). vendor_id +
-- vendor_contact_id were added in phase0_01_vendors; this completes the
-- triplet by adding brand_id, mirroring proposal_items.brand_id.
--
-- The picker UX restricts a component's brand to brands carried by its
-- chosen vendor — but the FK is the same as items: brand exists at the
-- studio level, the value is just the brand_id reference.
--
-- Idempotent.

alter table proposal_components
  add column if not exists brand_id uuid references brands(id) on delete set null;

create index if not exists idx_components_brand
  on proposal_components(brand_id)
  where brand_id is not null and deleted_at is null;

-- Verify
select column_name, data_type, is_nullable
  from information_schema.columns
  where table_name = 'proposal_components' and column_name = 'brand_id';

select indexname from pg_indexes where indexname = 'idx_components_brand';
