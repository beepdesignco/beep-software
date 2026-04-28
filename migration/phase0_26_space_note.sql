-- Phase 0, step 26 — internal note on each proposal_space.
--
-- Free-text room/space note that surfaces in the proposal builder
-- below the space's items list and on a new "Rooms / Spaces"
-- list-export type. Internal — never visible client-side.
--
-- Idempotent.

begin;

alter table proposal_spaces
  add column if not exists note text;

commit;

select column_name, data_type from information_schema.columns
  where table_name = 'proposal_spaces' and column_name = 'note';
