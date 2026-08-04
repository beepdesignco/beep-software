-- phase0_65 — §4.1 Item spec system (THE KEYSTONE)
-- Per-category specification fields on proposal items + components.
-- item_field_defs follows task_field_defs' shape, keyed to item_type_id.
-- Values live in a nullable spec jsonb on proposal_items /
-- proposal_components: { field_key: value }. Fully additive.
-- Rollback: drop table item_field_defs;
--           alter table proposal_items drop column spec;
--           alter table proposal_components drop column spec;

begin;

create table if not exists item_field_defs (
  id uuid primary key,
  studio_id    uuid not null references studios(id) on delete cascade,
  item_type_id uuid not null references item_types(id) on delete cascade,
  field_key  text not null,
  label      text not null,
  field_type text not null default 'text',   -- text | number | select | date | textarea
  options    jsonb not null default '[]'::jsonb,   -- select choices: ["a","b"]
  required   boolean not null default false,
  applies_to jsonb not null default '["readymade","openline","constructed"]'::jsonb,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists item_field_defs_type_idx
  on item_field_defs (studio_id, item_type_id, sort_order) where deleted_at is null;

alter table item_field_defs enable row level security;

drop policy if exists item_field_defs_member_all on item_field_defs;
create policy item_field_defs_member_all on item_field_defs
  for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

alter table proposal_items      add column if not exists spec jsonb;
alter table proposal_components add column if not exists spec jsonb;

commit;

-- Verification
select
  (select count(*) from information_schema.tables  where table_name = 'item_field_defs')                                as defs_table,
  (select count(*) from information_schema.columns where table_name = 'proposal_items'      and column_name = 'spec')  as item_spec,
  (select count(*) from information_schema.columns where table_name = 'proposal_components' and column_name = 'spec')  as comp_spec;
