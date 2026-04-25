-- Phase 0, step 6b — Submittal signers reference vendor_contacts.
--
-- Original schema FK'd submittal_signers.contact_id at contacts(id), but we
-- folded contacts into vendor_contacts in an earlier pass. Adds vendor_contact_id
-- alongside, drops NOT NULL on the legacy contact_id so new signers reference
-- the unified contacts model.
--
-- Idempotent.

alter table submittal_signers alter column contact_id drop not null;

alter table submittal_signers
  add column if not exists vendor_contact_id uuid references vendor_contacts(id) on delete cascade;

create index if not exists idx_submittal_signers_vc
  on submittal_signers(vendor_contact_id)
  where vendor_contact_id is not null;

create unique index if not exists uq_submittal_signers_vc_per_submittal
  on submittal_signers(submittal_id, vendor_contact_id)
  where vendor_contact_id is not null;

-- Verify
select column_name, is_nullable from information_schema.columns
  where table_name = 'submittal_signers' and column_name in ('contact_id', 'vendor_contact_id')
  order by column_name;

select indexname from pg_indexes where indexname in ('idx_submittal_signers_vc', 'uq_submittal_signers_vc_per_submittal');
