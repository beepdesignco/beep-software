-- Phase 0, step 30 — system_key column on item_types for built-in defaults.
--
-- Two built-in item types ("Undefined" and "Non-Material Item / Service")
-- get auto-seeded for every studio. Tagging them with a stable system_key
-- (rather than matching by name) lets users rename / recolor without
-- breaking the link, and lets us refuse deletion to keep the defaults
-- always present.
--
-- Existing rows get NULL — only newly-seeded built-ins set system_key.
--
-- Idempotent.

begin;

alter table item_types
  add column if not exists system_key text;

create index if not exists idx_item_types_system_key
  on item_types(studio_id, system_key)
  where system_key is not null and deleted_at is null;

commit;

-- Verify
select column_name, data_type, is_nullable from information_schema.columns
  where table_name = 'item_types' and column_name = 'system_key';
