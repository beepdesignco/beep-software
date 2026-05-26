-- Phase 0, step 1 — Vendors + vendor_contacts.
--
-- Adds first-class vendor entities plus optional vendor_contact sub-entities.
-- Decoupled from the existing `contacts` table (contacts = people connected to
-- clients/projects; vendor_contacts = reps/accounts connected to a vendor).
--
-- Data migration sources:
--   • proposal_items.contact           → vendors.name (vendor_type null)
--   • proposal_components.contact      → vendors.name (vendor_type null)
--   • projects.address_book.{role}.name where role in
--       (receiver, contractor, architect, landscape_architect)
--     → vendors.name (vendor_type = initcap of role)
--   • projects.address_book.{role}.contacts[]
--     → vendor_contacts under the matching vendor
--
-- Existing text columns (proposal_items.contact, proposal_components.contact,
-- projects.address_book) are LEFT IN PLACE. The UI will prefer vendor_id when
-- present and fall back to the legacy text field until later phases tidy up.
--
-- Idempotent: safe to run again. Uses NOT EXISTS guards instead of ON CONFLICT
-- against a partial unique index so we don't have to restate the predicate.

begin;

-- ════════════════════════════════════════════════════════════════
-- VENDORS
-- ════════════════════════════════════════════════════════════════

create table if not exists vendors (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  name                text not null,
  vendor_type         text,              -- free-form label; studio list lives in studios.settings.vendor_types
  website             text,
  phone               text,
  email               text,
  address             text,
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  created_by_user_id  uuid references auth.users(id),
  updated_by_user_id  uuid references auth.users(id)
);

create index if not exists idx_vendors_studio on vendors(studio_id) where deleted_at is null;

-- Case-insensitive uniqueness per studio (live rows only; soft-deleted names can be reused)
create unique index if not exists uq_vendors_studio_name_ci
  on vendors (studio_id, lower(name))
  where deleted_at is null;

alter table vendors enable row level security;

drop policy if exists vendors_all on vendors;
create policy vendors_all on vendors for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

-- updated_at trigger (mirrors pattern in schema.sql)
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'vendors_set_updated_at') then
    create trigger vendors_set_updated_at before update on vendors
      for each row execute function set_updated_at();
  end if;
end $$;

-- ════════════════════════════════════════════════════════════════
-- VENDOR_CONTACTS
-- ════════════════════════════════════════════════════════════════

create table if not exists vendor_contacts (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  vendor_id           uuid not null references vendors(id) on delete cascade,
  name                text not null,
  title               text,
  email               text,
  phone               text,
  notes               text,
  primary_contact     boolean not null default false,
  sort_order          integer not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  created_by_user_id  uuid references auth.users(id),
  updated_by_user_id  uuid references auth.users(id)
);

create index if not exists idx_vendor_contacts_vendor on vendor_contacts(vendor_id) where deleted_at is null;
create index if not exists idx_vendor_contacts_studio on vendor_contacts(studio_id) where deleted_at is null;

-- At most one primary contact per vendor
create unique index if not exists uq_vendor_contacts_primary
  on vendor_contacts(vendor_id)
  where primary_contact = true and deleted_at is null;

alter table vendor_contacts enable row level security;

drop policy if exists vendor_contacts_all on vendor_contacts;
create policy vendor_contacts_all on vendor_contacts for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'vendor_contacts_set_updated_at') then
    create trigger vendor_contacts_set_updated_at before update on vendor_contacts
      for each row execute function set_updated_at();
  end if;
end $$;

-- ════════════════════════════════════════════════════════════════
-- FK COLUMNS ON PROPOSAL ITEMS / COMPONENTS
-- Legacy `.contact` text column retained for fallback + audit.
-- ════════════════════════════════════════════════════════════════

alter table proposal_items
  add column if not exists vendor_id         uuid references vendors(id) on delete set null,
  add column if not exists vendor_contact_id uuid references vendor_contacts(id) on delete set null;

alter table proposal_components
  add column if not exists vendor_id         uuid references vendors(id) on delete set null,
  add column if not exists vendor_contact_id uuid references vendor_contacts(id) on delete set null;

create index if not exists idx_items_vendor
  on proposal_items(vendor_id)
  where vendor_id is not null and deleted_at is null;

create index if not exists idx_components_vendor
  on proposal_components(vendor_id)
  where vendor_id is not null and deleted_at is null;

-- ════════════════════════════════════════════════════════════════
-- DATA MIGRATION — VENDORS
-- Collapse every source name into one row per (studio_id, lower(name)),
-- preferring an address-book-derived vendor_type when available.
-- ════════════════════════════════════════════════════════════════

with item_sources as (
  select
    p.studio_id,
    trim(pi.contact) as name,
    null::text       as vendor_type
  from proposal_items pi
  join proposal_spaces ps on ps.id = pi.space_id
  join projects p         on p.id = ps.project_id
  where pi.contact is not null
    and trim(pi.contact) <> ''
    and pi.deleted_at is null
),
component_sources as (
  select
    p.studio_id,
    trim(pc.contact) as name,
    null::text       as vendor_type
  from proposal_components pc
  join proposal_items pi  on pi.id = pc.item_id
  join proposal_spaces ps on ps.id = pi.space_id
  join projects p         on p.id = ps.project_id
  where pc.contact is not null
    and trim(pc.contact) <> ''
    and pc.deleted_at is null
),
addressbook_sources as (
  select
    p.studio_id,
    trim(role_entry.value->>'name')                      as name,
    initcap(replace(role_entry.key, '_', ' '))           as vendor_type
  from projects p,
       jsonb_each(coalesce(p.address_book, '{}'::jsonb)) as role_entry
  where role_entry.key in ('receiver', 'contractor', 'architect', 'landscape_architect')
    and jsonb_typeof(role_entry.value) = 'object'
    and role_entry.value ? 'name'
    and trim(role_entry.value->>'name') <> ''
    and p.deleted_at is null
),
all_sources as (
  select * from item_sources
  union all
  select * from component_sources
  union all
  select * from addressbook_sources
),
collapsed as (
  -- One row per (studio, name-lowercased); non-null vendor_type wins via ORDER BY
  select distinct on (studio_id, lower(name))
    studio_id,
    name,
    vendor_type
  from all_sources
  order by studio_id, lower(name), vendor_type nulls last
)
insert into vendors (studio_id, name, vendor_type)
select c.studio_id, c.name, c.vendor_type
from collapsed c
where not exists (
  select 1 from vendors v
  where v.studio_id = c.studio_id
    and lower(v.name) = lower(c.name)
    and v.deleted_at is null
);

-- ════════════════════════════════════════════════════════════════
-- DATA MIGRATION — VENDOR_CONTACTS (from address_book contacts[])
-- Each role's contacts[] entries become vendor_contacts under the role's vendor.
-- ════════════════════════════════════════════════════════════════

with ab_contacts as (
  select
    p.studio_id,
    trim(role_entry.value->>'name')                             as vendor_name,
    contact_entry.value                                         as contact
  from projects p,
       jsonb_each(coalesce(p.address_book, '{}'::jsonb))        as role_entry,
       jsonb_array_elements(
         case when jsonb_typeof(role_entry.value->'contacts') = 'array'
              then role_entry.value->'contacts'
              else '[]'::jsonb
         end
       ) as contact_entry
  where role_entry.key in ('receiver', 'contractor', 'architect', 'landscape_architect')
    and jsonb_typeof(role_entry.value) = 'object'
    and trim(coalesce(role_entry.value->>'name', '')) <> ''
    and trim(coalesce(contact_entry.value->>'name', '')) <> ''
    and p.deleted_at is null
),
distinct_contacts as (
  select distinct on (studio_id, lower(vendor_name), lower(trim(contact->>'name')))
    studio_id,
    vendor_name,
    trim(contact->>'name')                 as contact_name,
    nullif(trim(contact->>'title'), '')    as title,
    nullif(trim(contact->>'phone'), '')    as phone,
    nullif(trim(contact->>'notes'), '')    as notes
  from ab_contacts
  order by studio_id, lower(vendor_name), lower(trim(contact->>'name'))
)
insert into vendor_contacts (studio_id, vendor_id, name, title, phone, notes)
select
  dc.studio_id,
  v.id,
  dc.contact_name,
  dc.title,
  dc.phone,
  dc.notes
from distinct_contacts dc
join vendors v
  on v.studio_id = dc.studio_id
 and lower(v.name) = lower(dc.vendor_name)
 and v.deleted_at is null
where not exists (
  select 1 from vendor_contacts vc
  where vc.vendor_id = v.id
    and lower(vc.name) = lower(dc.contact_name)
    and vc.deleted_at is null
);

-- ════════════════════════════════════════════════════════════════
-- BACKFILL vendor_id ON proposal_items + proposal_components
-- Name match within the same studio.
-- ════════════════════════════════════════════════════════════════

update proposal_items pi
set vendor_id = v.id
from proposal_spaces ps,
     projects p,
     vendors v
where pi.space_id    = ps.id
  and ps.project_id  = p.id
  and v.studio_id    = p.studio_id
  and v.deleted_at   is null
  and lower(v.name)  = lower(trim(pi.contact))
  and pi.contact     is not null
  and trim(pi.contact) <> ''
  and pi.vendor_id   is null
  and pi.deleted_at  is null;

update proposal_components pc
set vendor_id = v.id
from proposal_items pi,
     proposal_spaces ps,
     projects p,
     vendors v
where pc.item_id     = pi.id
  and pi.space_id    = ps.id
  and ps.project_id  = p.id
  and v.studio_id    = p.studio_id
  and v.deleted_at   is null
  and lower(v.name)  = lower(trim(pc.contact))
  and pc.contact     is not null
  and trim(pc.contact) <> ''
  and pc.vendor_id   is null
  and pc.deleted_at  is null;

commit;

-- ════════════════════════════════════════════════════════════════
-- MIGRATION RESULTS — run these after the transaction commits
-- and paste the output back so we can confirm coverage before moving on.
-- ════════════════════════════════════════════════════════════════

select 'vendors created'                                         as label, count(*) from vendors where deleted_at is null;
select 'vendor_contacts created'                                 as label, count(*) from vendor_contacts where deleted_at is null;

select 'items linked to a vendor'                                as label, count(*)
  from proposal_items where vendor_id is not null and deleted_at is null;

select 'items with leftover .contact but no vendor_id'           as label, count(*)
  from proposal_items
  where vendor_id is null and contact is not null and trim(contact) <> '' and deleted_at is null;

select 'components linked to a vendor'                           as label, count(*)
  from proposal_components where vendor_id is not null and deleted_at is null;

select 'components with leftover .contact but no vendor_id'      as label, count(*)
  from proposal_components
  where vendor_id is null and contact is not null and trim(contact) <> '' and deleted_at is null;

-- Top 20 vendors by how many items currently reference them
select v.name, v.vendor_type, count(pi.*) as item_count
  from vendors v
  left join proposal_items pi on pi.vendor_id = v.id and pi.deleted_at is null
  where v.deleted_at is null
  group by v.id, v.name, v.vendor_type
  order by item_count desc, v.name
  limit 20;

-- Any items whose trimmed .contact didn't match a vendor name (should be zero
-- because everything should have been inserted; non-zero means casing or
-- whitespace weirdness worth investigating).
select pi.id, pi.name, pi.contact
  from proposal_items pi
  where pi.vendor_id is null
    and pi.contact is not null
    and trim(pi.contact) <> ''
    and pi.deleted_at is null
  limit 10;
