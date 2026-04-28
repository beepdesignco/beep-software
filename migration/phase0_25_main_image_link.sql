-- Phase 0, step 25 — main_image_id + main_link_url on proposal_items.
--
-- Two starring fields. When set, list exports surface only the starred
-- value (image / link); when null, lists fall back to first-image and
-- list all links numbered "Link {1}".."Link {N}".
--
-- main_image_id is the file id (uuid string) inside item.files; we
-- store it as text so we don't need a separate FK to a non-existent
-- files table (files live as jsonb on the item row).
--
-- main_link_url is the bare URL string (links live as a jsonb string[]
-- on the item; we starred-by-value rather than introducing index drift
-- when links are reordered).
--
-- Idempotent.

begin;

alter table proposal_items
  add column if not exists main_image_id text,
  add column if not exists main_link_url text;

commit;

select column_name, data_type from information_schema.columns
  where table_name = 'proposal_items'
    and column_name in ('main_image_id', 'main_link_url');
