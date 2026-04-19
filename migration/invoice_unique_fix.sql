-- Invoice number uniqueness should only apply to non-deleted rows.
-- Otherwise a cancelled/soft-deleted invoice still holds its number forever,
-- and the app (which filters deleted rows out of S) will try to reuse it.

alter table invoices drop constraint if exists invoices_studio_id_number_key;

-- Partial unique index: only enforce uniqueness on live rows.
create unique index if not exists invoices_studio_number_live_unique
  on invoices(studio_id, number) where deleted_at is null;
