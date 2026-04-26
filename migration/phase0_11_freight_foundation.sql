-- Phase 0, step 11 — Freight tracking foundation (U-Freight Phase 1).
--
-- Lays the schema + configuration foundation for the freight rebuild:
--   • freight_categories — studio-configurable charge categories with
--     markup/tax defaults. Seeds 9 system rows per studio.
--   • freight_charges — typed per-item / per-component freight charges,
--     with state machine (known/allowance/deferred/none) + value triplet
--     rule enforced via CHECK.
--   • Adds expenses.proposal_item_id for actual-cost reconciliation.
--   • Drops legacy proposal_items.actual_freight + proposal_components.actual_freight.
--   • Wipes proposal_items.additional_charges (test data; new model lives
--     in freight_charges going forward).
--
-- Subsequent phases build the UI on top:
--   Phase 2 — freight charge UI on Add/Edit Item modal + components
--   Phase 3 — expense → item linkage UI + Project Expenses tab
--   Phase 4 — project freight ledger + reconciliation
--   Phase 5 — invoice integration
--   Phase 6 — Estimate Builder cleanup
--
-- Idempotent.

begin;

-- ════════════════════════════════════════════════════════════════
-- freight_categories
-- ════════════════════════════════════════════════════════════════

create table if not exists freight_categories (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  name                text not null,
  default_markup_pct  numeric(6,2),                    -- null = use project default at calc time; explicit 0 = no markup
  is_taxable          boolean not null default true,   -- still gated by project freight_tax + project state rate
  sort_order          integer not null default 0,
  is_system           boolean not null default false,  -- seeded vs user-created; system rows can be edited but not deleted
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  created_by_user_id  uuid references auth.users(id),
  updated_by_user_id  uuid references auth.users(id)
);

create index if not exists idx_freight_categories_studio
  on freight_categories(studio_id, sort_order)
  where deleted_at is null;

create unique index if not exists uq_freight_categories_studio_name_ci
  on freight_categories (studio_id, lower(name))
  where deleted_at is null;

alter table freight_categories enable row level security;

drop policy if exists freight_categories_all on freight_categories;
create policy freight_categories_all on freight_categories for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'freight_categories_set_updated_at') then
    create trigger freight_categories_set_updated_at before update on freight_categories
      for each row execute function set_updated_at();
  end if;
end $$;

-- ════════════════════════════════════════════════════════════════
-- freight_charges
-- ════════════════════════════════════════════════════════════════
-- parent_id is polymorphic — references either proposal_items.id or
-- proposal_components.id depending on parent_type. App-layer maintains
-- referential integrity at sync time (matches existing patterns for
-- soft-deleted parents). category_id is nullable + on delete set null
-- so deleting a category gracefully orphans charges instead of failing
-- the sync.

create table if not exists freight_charges (
  id                   uuid primary key default gen_random_uuid(),
  studio_id            uuid not null references studios(id) on delete cascade,
  parent_type          text not null,
  parent_id            uuid not null,
  category_id          uuid references freight_categories(id) on delete set null,
  state                text not null,
  value_type           text,
  value                numeric(12,2),
  markup_pct_override  numeric(6,2),
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz,
  created_by_user_id   uuid references auth.users(id),
  updated_by_user_id   uuid references auth.users(id),
  constraint freight_charges_parent_type_chk check (parent_type in ('item', 'component')),
  constraint freight_charges_state_chk       check (state in ('known', 'allowance', 'deferred', 'none')),
  constraint freight_charges_value_state_chk check (
    (state in ('known', 'allowance') and value_type in ('amount', 'percent') and value is not null)
    or
    (state in ('deferred', 'none') and value_type is null and value is null)
  )
);

create index if not exists idx_freight_charges_parent
  on freight_charges(studio_id, parent_type, parent_id)
  where deleted_at is null;

create index if not exists idx_freight_charges_category
  on freight_charges(category_id)
  where deleted_at is null;

alter table freight_charges enable row level security;

drop policy if exists freight_charges_all on freight_charges;
create policy freight_charges_all on freight_charges for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'freight_charges_set_updated_at') then
    create trigger freight_charges_set_updated_at before update on freight_charges
      for each row execute function set_updated_at();
  end if;
end $$;

-- ════════════════════════════════════════════════════════════════
-- expenses.proposal_item_id — link an expense to a specific item
-- for actual-cost reconciliation. UI surfacing comes in Phase 3.
-- ════════════════════════════════════════════════════════════════

alter table expenses
  add column if not exists proposal_item_id uuid references proposal_items(id) on delete set null;

create index if not exists idx_expenses_proposal_item
  on expenses(proposal_item_id)
  where proposal_item_id is not null and deleted_at is null;

-- ════════════════════════════════════════════════════════════════
-- DROP legacy actual_freight columns.
-- Replaced by expenses linked via proposal_item_id (Phase 3+).
-- ════════════════════════════════════════════════════════════════

alter table proposal_items      drop column if exists actual_freight;
alter table proposal_components drop column if exists actual_freight;

-- ════════════════════════════════════════════════════════════════
-- WIPE proposal_items.additional_charges jsonb.
-- Test data only (confirmed safe). The new freight charges model lives
-- in freight_charges going forward; the additional_charges column
-- itself stays for now and gets retired in Phase 2.
-- ════════════════════════════════════════════════════════════════

update proposal_items
  set additional_charges = '[]'::jsonb
  where additional_charges is distinct from '[]'::jsonb;

-- ════════════════════════════════════════════════════════════════
-- SEED — 9 system categories per existing studio (idempotent).
-- ════════════════════════════════════════════════════════════════

insert into freight_categories (studio_id, name, default_markup_pct, is_taxable, sort_order, is_system)
select s.id, c.name, c.default_markup_pct, c.is_taxable, c.sort_order, true
from studios s
cross join (values
  ('Freight',              null::numeric, true,  1),
  ('Crating',              null::numeric, true,  2),
  ('Tariffs',              0::numeric,    false, 3),
  ('Handling',             null::numeric, true,  4),
  ('Fuel Surcharge',       null::numeric, true,  5),
  ('Residential Delivery', null::numeric, true,  6),
  ('Lift Gate',            null::numeric, true,  7),
  ('Storage Transfer',     null::numeric, true,  8),
  ('Other',                null::numeric, true,  9)
) as c(name, default_markup_pct, is_taxable, sort_order)
where not exists (
  select 1 from freight_categories fc
  where fc.studio_id = s.id
    and lower(fc.name) = lower(c.name)
    and fc.deleted_at is null
);

-- ════════════════════════════════════════════════════════════════
-- AUTO-SEED — trigger to seed system categories on every new studio.
-- SECURITY DEFINER bypasses RLS during the post-insert hook (the user
-- creating the studio isn't yet a studio member at that moment).
-- search_path is pinned + tables are schema-qualified per the SECURITY
-- DEFINER hardening pattern documented in the Supabase RLS lesson memo.
-- ════════════════════════════════════════════════════════════════

create or replace function seed_studio_freight_categories()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.freight_categories
    (studio_id, name, default_markup_pct, is_taxable, sort_order, is_system)
  values
    (new.id, 'Freight',              null,  true,  1, true),
    (new.id, 'Crating',              null,  true,  2, true),
    (new.id, 'Tariffs',              0,     false, 3, true),
    (new.id, 'Handling',             null,  true,  4, true),
    (new.id, 'Fuel Surcharge',       null,  true,  5, true),
    (new.id, 'Residential Delivery', null,  true,  6, true),
    (new.id, 'Lift Gate',            null,  true,  7, true),
    (new.id, 'Storage Transfer',     null,  true,  8, true),
    (new.id, 'Other',                null,  true,  9, true);
  return new;
end $$;

grant execute on function seed_studio_freight_categories() to authenticated;

drop trigger if exists studios_seed_freight_categories on studios;
create trigger studios_seed_freight_categories
  after insert on studios
  for each row
  execute function seed_studio_freight_categories();

commit;

-- ════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- ════════════════════════════════════════════════════════════════

-- 1. New tables exist (expect 2).
select table_name from information_schema.tables
  where table_schema = 'public' and table_name in ('freight_categories', 'freight_charges')
  order by table_name;

-- 2. Legacy actual_freight columns are gone (expect 0).
select count(*) as legacy_actual_freight_remaining
  from information_schema.columns
  where (table_name = 'proposal_items' or table_name = 'proposal_components')
    and column_name = 'actual_freight';

-- 3. expenses.proposal_item_id exists, nullable (expect 1 row: uuid, YES).
select column_name, data_type, is_nullable
  from information_schema.columns
  where table_name = 'expenses' and column_name = 'proposal_item_id';

-- 4. additional_charges wipe (expect 0).
select count(*) as items_with_nonempty_charges
  from proposal_items
  where additional_charges is distinct from '[]'::jsonb and deleted_at is null;

-- 5. Per-studio seed counts (expect 9 per studio).
select studio_id, count(*) as system_categories
  from freight_categories
  where is_system = true and deleted_at is null
  group by studio_id;

-- 6. Auto-seed trigger registered (expect 1 row).
select tgname from pg_trigger where tgname = 'studios_seed_freight_categories';

-- 7. RLS policies on the new tables (expect 2 rows).
select policyname, tablename from pg_policies
  where tablename in ('freight_categories','freight_charges')
  order by tablename, policyname;
