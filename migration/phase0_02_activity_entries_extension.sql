-- Phase 0, step 2 — activity_entries extension.
--
-- Adds the columns needed for system-emitted event rows:
--   source      — who emitted the row: 'user' | 'system' | 'email' | 'import'
--   is_locked   — prevents edit/delete (enforced at RLS layer)
--   event_type  — free-form 'entity.action' string; null for plain user notes
--   payload     — jsonb metadata for system events; null for plain user notes
--
-- Behavior rules (from spec):
--   • User notes keep their existing shape (source='user', is_locked=false,
--     event_type=null, payload=null). Backfill handles that automatically.
--   • System events MUST be locked (CHECK constraint enforces it).
--   • Any source other than 'user' is implicitly locked.
--   • mentions[] stays on user notes only; system events leave it empty.
--   • body/text on system events is a pre-rendered human-readable string
--     (emitters do this so the chronological chart can display without
--     re-rendering from payload every time).
--
-- RLS changes:
--   • The existing `activity_all` combined policy is replaced with split
--     SELECT / INSERT / UPDATE / DELETE policies so we can:
--       - still let any studio member read everything
--       - prevent regular users from inserting source != 'user'
--         (security-definer functions that bypass RLS do the system inserts)
--       - block update + delete on rows where is_locked = true
--
-- Idempotent: safe to re-run.

begin;

-- ════════════════════════════════════════════════════════════════
-- COLUMNS
-- ════════════════════════════════════════════════════════════════

alter table activity_entries
  add column if not exists source     text not null default 'user',
  add column if not exists is_locked  boolean not null default false,
  add column if not exists event_type text,
  add column if not exists payload    jsonb;

-- Enforce the allowed source values + the "non-user sources must be locked" rule.
-- Guarded by a do-block so re-running the migration doesn't error on duplicates.

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'activity_entries_source_check'
  ) then
    alter table activity_entries
      add constraint activity_entries_source_check
      check (source in ('user', 'system', 'email', 'import'));
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'activity_entries_locked_for_nonuser'
  ) then
    alter table activity_entries
      add constraint activity_entries_locked_for_nonuser
      check (source = 'user' or is_locked = true);
  end if;
end $$;

-- Index for Feature 8 (chronological chart) + Feature 15 (weekly digest):
-- fast lookup of system events within a studio ordered by time.
create index if not exists idx_activity_event_type
  on activity_entries(studio_id, event_type, created_at desc)
  where event_type is not null and deleted_at is null;

-- Index for filtering by source (e.g. only show system events).
create index if not exists idx_activity_source
  on activity_entries(studio_id, source, created_at desc)
  where deleted_at is null;

-- ════════════════════════════════════════════════════════════════
-- RLS — replace the single combined policy with split per-verb policies
-- ════════════════════════════════════════════════════════════════

drop policy if exists activity_all on activity_entries;

drop policy if exists activity_select on activity_entries;
drop policy if exists activity_insert on activity_entries;
drop policy if exists activity_update on activity_entries;
drop policy if exists activity_delete on activity_entries;

-- SELECT — any studio member can see every entry for their studio.
create policy activity_select on activity_entries for select
  using (is_studio_member(studio_id));

-- INSERT — a regular user can only insert a row they own with source='user'.
-- System/email/import rows must be inserted by security-definer functions or
-- the service role (both bypass RLS).
create policy activity_insert on activity_entries for insert
  with check (
    is_studio_member(studio_id)
    and source = 'user'
  );

-- UPDATE — only unlocked rows, only for studio members.
create policy activity_update on activity_entries for update
  using (is_studio_member(studio_id) and is_locked = false)
  with check (is_studio_member(studio_id) and is_locked = false);

-- DELETE (includes soft-delete via `deleted_at` set) — only unlocked rows.
create policy activity_delete on activity_entries for delete
  using (is_studio_member(studio_id) and is_locked = false);

commit;

-- ════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES — run after the commit and paste output back.
-- ════════════════════════════════════════════════════════════════

-- 1. Confirm columns exist with expected types + defaults.
select column_name, data_type, is_nullable, column_default
  from information_schema.columns
  where table_name = 'activity_entries'
    and column_name in ('source', 'is_locked', 'event_type', 'payload')
  order by column_name;

-- 2. Confirm CHECK constraints are present.
select conname, pg_get_constraintdef(oid) as definition
  from pg_constraint
  where conrelid = 'activity_entries'::regclass
    and conname in ('activity_entries_source_check', 'activity_entries_locked_for_nonuser');

-- 3. Confirm the new RLS policies are active (expect 4 rows: select/insert/update/delete).
select policyname, cmd, qual, with_check
  from pg_policies
  where tablename = 'activity_entries'
  order by policyname;

-- 4. Backfill sanity check — every existing row should now have source='user',
--    is_locked=false, event_type=null, payload=null.
select count(*) as total_rows,
       count(*) filter (where source = 'user')        as source_user,
       count(*) filter (where is_locked = false)      as unlocked,
       count(*) filter (where event_type is null)     as no_event_type,
       count(*) filter (where payload is null)        as no_payload
  from activity_entries;
