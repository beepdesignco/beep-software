-- Phase 0, step 18 — per-user UI preferences on studio_members.
--
-- Adds a JSONB `preferences` bag on studio_members so per-user UI choices
-- (theme, future things like density / sidebar collapsed state / etc.)
-- follow the user across devices instead of living in localStorage.
--
-- Existing members_update RLS policy already allows a member to update
-- their own row (user_id = auth.uid()), so no policy changes needed.
--
-- Idempotent.

begin;

alter table studio_members
  add column if not exists preferences jsonb not null default '{}'::jsonb;

commit;

select column_name, data_type, column_default from information_schema.columns
  where table_name = 'studio_members' and column_name = 'preferences';
