-- Phase 0, step 9b — time_entries cutover prep.
--
-- Test-data-only wipe. Required because:
--   (a) The pre-existing manual-log modal wrote an in-memory shape that
--       didn't match the DB schema (missing started_at/ended_at etc.),
--       so any rows created through that path violate invariants.
--   (b) The new writes populate rate / status / invoice_line_item_id /
--       billed_at; starting empty avoids mixing old and new rows.
--
-- Safe per user confirmation. Idempotent.

delete from time_entries;

-- Verify
select count(*) as remaining from time_entries;
