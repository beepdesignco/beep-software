-- Phase 0, step 27 — per-member permission to manually adjust time entries.
--
-- When false: that user can run timers (start/stop) but cannot edit
-- duration / project / notes after the fact, and cannot manually log a
-- backdated entry. Owners always have permission regardless.
--
-- Defaults to true so existing members keep their current behavior.
--
-- Idempotent.

begin;

alter table studio_members
  add column if not exists can_adjust_time_entries boolean not null default true;

commit;

select column_name, data_type, column_default from information_schema.columns
  where table_name = 'studio_members' and column_name = 'can_adjust_time_entries';
