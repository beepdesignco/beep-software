-- Phase 0, step 1b — add client_id to vendor_contacts.
-- Preserves the "contact is tied to a specific client" relationship that lived
-- on the old contacts table when we fold those records into vendor_contacts.
-- Idempotent.

alter table vendor_contacts
  add column if not exists client_id uuid references clients(id) on delete set null;

create index if not exists idx_vendor_contacts_client
  on vendor_contacts(client_id)
  where client_id is not null and deleted_at is null;

-- Verification
select column_name, data_type, is_nullable
  from information_schema.columns
  where table_name = 'vendor_contacts' and column_name = 'client_id';

select indexname from pg_indexes where indexname = 'idx_vendor_contacts_client';
