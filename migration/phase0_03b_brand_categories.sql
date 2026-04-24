-- Phase 0, step 3b — add categories to brands.
-- Each brand can be tagged with one or more product categories (Lighting,
-- Textile, Furniture, Tile, etc.). Categories list lives in
-- studios.settings.categories (same studio-configurable pattern as qty_units
-- and task statuses) — this column just holds the picked values.
-- Idempotent.

alter table brands
  add column if not exists categories text[] not null default '{}';

-- GIN index so "which brands sell this category" is fast for filtering.
create index if not exists idx_brands_categories
  on brands using gin (categories);

-- Verification
select column_name, data_type, is_nullable, column_default
  from information_schema.columns
  where table_name = 'brands' and column_name = 'categories';

select indexname from pg_indexes where indexname = 'idx_brands_categories';
