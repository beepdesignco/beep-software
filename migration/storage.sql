-- BEEP HQ — Supabase Storage bucket + RLS (Phase F)
-- Creates one private 'files' bucket. Objects are pathed as:
--   {studio_id}/{entity_type}/{entity_id}/{uuid}_{filename}
-- Members can only read/write objects under their own studio_id prefix.

-- ── Create the bucket (safe to re-run)
insert into storage.buckets (id, name, public)
values ('files', 'files', false)
on conflict (id) do nothing;

-- ── Helpful function: extract studio_id (first path segment) from a storage object's name
create or replace function storage_studio_id(obj_name text)
returns uuid language sql immutable as $$
  select nullif(split_part(obj_name, '/', 1), '')::uuid
$$;

-- ── Policies on storage.objects for the 'files' bucket
drop policy if exists files_select on storage.objects;
drop policy if exists files_insert on storage.objects;
drop policy if exists files_update on storage.objects;
drop policy if exists files_delete on storage.objects;

create policy files_select on storage.objects for select
  using (bucket_id = 'files' and is_studio_member(storage_studio_id(name)));

create policy files_insert on storage.objects for insert
  with check (bucket_id = 'files' and is_studio_member(storage_studio_id(name)));

create policy files_update on storage.objects for update
  using (bucket_id = 'files' and is_studio_member(storage_studio_id(name)))
  with check (bucket_id = 'files' and is_studio_member(storage_studio_id(name)));

create policy files_delete on storage.objects for delete
  using (bucket_id = 'files' and is_studio_member(storage_studio_id(name)));
