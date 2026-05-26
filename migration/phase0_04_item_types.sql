-- Phase 0, step 4 — Item types taxonomy.
--
-- Studio-configurable master list of "item type" tags (e.g. Furniture,
-- Lighting, Textile, Window Treatment, Accessory). One type per item.
--
-- Stored as a table (not a jsonb array) because proposal_items.item_type_id
-- is a FK. Each studio maintains its own list; reorder via sort_order;
-- soft-delete preserves historical tagging.
--
-- Optional `color` column so the UI can display item types as colored pills
-- alongside status pills on the proposal view. Nullable — UI can fall back
-- to a default when unset.
--
-- No data migration — this is a new concept. Existing items get
-- item_type_id = null until a user tags them.
--
-- Idempotent: safe to re-run.

begin;

-- ════════════════════════════════════════════════════════════════
-- ITEM_TYPES
-- ════════════════════════════════════════════════════════════════

create table if not exists item_types (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  name                text not null,
  description         text,
  color               text,                              -- optional hex for pill display
  sort_order          integer not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  created_by_user_id  uuid references auth.users(id),
  updated_by_user_id  uuid references auth.users(id)
);

create index if not exists idx_item_types_studio
  on item_types(studio_id, sort_order)
  where deleted_at is null;

-- Case-insensitive uniqueness per studio
create unique index if not exists uq_item_types_studio_name_ci
  on item_types (studio_id, lower(name))
  where deleted_at is null;

alter table item_types enable row level security;

drop policy if exists item_types_all on item_types;
create policy item_types_all on item_types for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'item_types_set_updated_at') then
    create trigger item_types_set_updated_at before update on item_types
      for each row execute function set_updated_at();
  end if;
end $$;

-- ════════════════════════════════════════════════════════════════
-- FK ON proposal_items
-- ════════════════════════════════════════════════════════════════

alter table proposal_items
  add column if not exists item_type_id uuid references item_types(id) on delete set null;

create index if not exists idx_items_item_type
  on proposal_items(item_type_id)
  where item_type_id is not null and deleted_at is null;

commit;

-- ════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- ════════════════════════════════════════════════════════════════

-- 1. item_types table exists (expect 1 row).
select table_name from information_schema.tables
  where table_schema = 'public' and table_name = 'item_types';

-- 2. New column on proposal_items (expect 1 row: uuid, YES).
select column_name, data_type, is_nullable
  from information_schema.columns
  where table_name = 'proposal_items' and column_name = 'item_type_id';

-- 3. RLS policy on item_types (expect 1 row: item_types_all, ALL).
select policyname, cmd from pg_policies
  where tablename = 'item_types' order by policyname;

-- 4. Indexes (expect 3: idx_item_types_studio, uq_item_types_studio_name_ci, idx_items_item_type).
select indexname, tablename from pg_indexes
  where indexname in (
    'idx_item_types_studio',
    'uq_item_types_studio_name_ci',
    'idx_items_item_type'
  )
  order by indexname;
