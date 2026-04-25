-- Phase 0, step 6c — let clients be signers on submittals.
--
-- Some submittals need the studio's CLIENT to sign off, not a vendor contact.
-- This adds a nullable client_id alongside the existing vendor_contact_id /
-- contact_id columns. Exactly one of the three identifies the signer.
-- App-layer enforces the "exactly one" rule.
--
-- Idempotent.

alter table submittal_signers
  add column if not exists client_id uuid references clients(id) on delete cascade;

create index if not exists idx_submittal_signers_client
  on submittal_signers(client_id)
  where client_id is not null;

create unique index if not exists uq_submittal_signers_client_per_submittal
  on submittal_signers(submittal_id, client_id)
  where client_id is not null;

-- Verify
select column_name, is_nullable from information_schema.columns
  where table_name = 'submittal_signers' and column_name = 'client_id';
select indexname from pg_indexes
  where indexname in ('idx_submittal_signers_client', 'uq_submittal_signers_client_per_submittal')
  order by indexname;
