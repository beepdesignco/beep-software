-- Phase 0, step 3 — Brands.
--
-- Optional tagging layer on top of vendors. Nothing is required; the whole
-- brand system exists to surface suggestions during vendor/contact pickers.
--
-- Data model:
--   brands             — studio-scoped master list (name, notes)
--   vendor_brands      — M2M: which vendors carry which brands, at a general level
--   vendor_contacts.brand_ids (uuid[]) — which specific reps rep which brands
--   proposal_items.brand_id           — item-level brand tag
--
-- No data migration — this is a new concept. Existing data is untouched.
--
-- Idempotent: safe to re-run.

begin;

-- ════════════════════════════════════════════════════════════════
-- BRANDS
-- ════════════════════════════════════════════════════════════════

create table if not exists brands (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  name                text not null,
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  created_by_user_id  uuid references auth.users(id),
  updated_by_user_id  uuid references auth.users(id)
);

create index if not exists idx_brands_studio on brands(studio_id) where deleted_at is null;

-- Case-insensitive uniqueness per studio (live rows only)
create unique index if not exists uq_brands_studio_name_ci
  on brands (studio_id, lower(name))
  where deleted_at is null;

alter table brands enable row level security;

drop policy if exists brands_all on brands;
create policy brands_all on brands for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'brands_set_updated_at') then
    create trigger brands_set_updated_at before update on brands
      for each row execute function set_updated_at();
  end if;
end $$;

-- ════════════════════════════════════════════════════════════════
-- VENDOR_BRANDS (M2M)
-- ════════════════════════════════════════════════════════════════

create table if not exists vendor_brands (
  vendor_id   uuid not null references vendors(id) on delete cascade,
  brand_id    uuid not null references brands(id)  on delete cascade,
  created_at  timestamptz not null default now(),
  created_by_user_id uuid references auth.users(id),
  primary key (vendor_id, brand_id)
);

create index if not exists idx_vendor_brands_brand on vendor_brands(brand_id);

alter table vendor_brands enable row level security;

-- Gate via the vendor's studio. (Brands and vendors in the same row always
-- share a studio — we'll enforce that at the app layer; if we ever get
-- paranoid we can add a CHECK via a trigger, but not worth it for MVP.)
drop policy if exists vendor_brands_all on vendor_brands;
create policy vendor_brands_all on vendor_brands for all
  using (
    exists (select 1 from vendors v where v.id = vendor_id and is_studio_member(v.studio_id))
  )
  with check (
    exists (select 1 from vendors v where v.id = vendor_id and is_studio_member(v.studio_id))
  );

-- ════════════════════════════════════════════════════════════════
-- vendor_contacts.brand_ids (uuid[])
-- ════════════════════════════════════════════════════════════════

alter table vendor_contacts
  add column if not exists brand_ids uuid[] not null default '{}';

-- GIN index so "which contacts rep brand X" is fast (used by the typeahead).
create index if not exists idx_vendor_contacts_brand_ids
  on vendor_contacts using gin (brand_ids);

-- ════════════════════════════════════════════════════════════════
-- proposal_items.brand_id
-- ════════════════════════════════════════════════════════════════

alter table proposal_items
  add column if not exists brand_id uuid references brands(id) on delete set null;

create index if not exists idx_items_brand
  on proposal_items(brand_id)
  where brand_id is not null and deleted_at is null;

commit;

-- ════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- ════════════════════════════════════════════════════════════════

-- 1. Brands + vendor_brands tables exist (expect 2 rows).
select table_name from information_schema.tables
  where table_schema = 'public'
    and table_name in ('brands', 'vendor_brands')
  order by table_name;

-- 2. New columns exist on vendor_contacts and proposal_items.
select table_name, column_name, data_type, is_nullable
  from information_schema.columns
  where (table_name = 'vendor_contacts' and column_name = 'brand_ids')
     or (table_name = 'proposal_items'  and column_name = 'brand_id')
  order by table_name, column_name;

-- 3. RLS policies on the new tables (expect 1 per table).
select tablename, policyname, cmd
  from pg_policies
  where tablename in ('brands', 'vendor_brands')
  order by tablename, policyname;

-- 4. Indexes exist (expect 5: uq_brands_studio_name_ci, idx_brands_studio,
--    idx_vendor_brands_brand, idx_vendor_contacts_brand_ids, idx_items_brand).
select indexname, tablename
  from pg_indexes
  where indexname in (
    'uq_brands_studio_name_ci',
    'idx_brands_studio',
    'idx_vendor_brands_brand',
    'idx_vendor_contacts_brand_ids',
    'idx_items_brand'
  )
  order by indexname;
