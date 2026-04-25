-- Phase 0, step 10 — assignee_user_id on proposal_items.
--
-- The Work Queue's "My Work" toggle needs a way to surface proposal items a
-- specific team member is responsible for. Existing columns don't capture
-- that — `created_by_user_id` reflects who entered the item, not who's
-- currently working it. This adds an explicit nullable assignee.
--
-- No UI yet. All items start null → Work Queue's My Work / Section B is
-- empty by design until a later prompt ships the picker.
--
-- NOTE on the index: proposal_items does not carry studio_id directly
-- (studio scoping flows through space_id → project_id → studio_id), so the
-- spec's (studio_id, assignee_user_id) index is applied as a single-column
-- partial index on assignee_user_id. This is sufficient for the My Work
-- filter since auth.uid() is already unique per user, and RLS scopes to
-- studio automatically.
--
-- Idempotent.

alter table proposal_items
  add column if not exists assignee_user_id uuid references auth.users(id) on delete set null;

create index if not exists idx_items_assignee
  on proposal_items(assignee_user_id)
  where assignee_user_id is not null and deleted_at is null;

-- Verification
select column_name, data_type, is_nullable
  from information_schema.columns
  where table_name = 'proposal_items' and column_name = 'assignee_user_id';

select indexname from pg_indexes where indexname = 'idx_items_assignee';
