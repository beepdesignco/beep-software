-- phase0_61 — Time billing transitions + single running timer (WORKLIST §6A.1 / §6A.9)
--
-- (1) BILLING TRANSITION POLICY. phase0_07's design locked billed rows at the
--     RLS layer, but every UPDATE policy carries status='unbilled' in BOTH
--     using and with_check — so the unbilled→billed flip (invoice save) and
--     the billed→unbilled revert (invoice delete/void/cancel) are BOTH
--     impossible from the client. That is why timeEntryToDB was left stubbed
--     and unbilled tallies never reconciled. This adds an OR'd policy letting
--     exactly the principals who can build invoices (owner or
--     can_edit_invoices members) write billed-state transitions on any
--     member's entries. Plain members without edit_invoices still cannot
--     touch billed rows. DELETE stays unbilled-only: billed rows are
--     reverted (via invoice deletion) before they can ever be deleted.
--
-- (2) ONE RUNNING TIMER PER USER. Partial unique index so two concurrent
--     ended_at-IS-NULL rows can never coexist for a user (Olivia ran web +
--     phone timers simultaneously on 2026-08-03; both apps only guard with
--     local UI state). Verified 0 users currently have >1 running row.
--
-- Rollback: drop policy time_update_billing on time_entries;
--           drop index one_running_timer_per_user;

begin;

drop policy if exists time_update_billing on time_entries;
create policy time_update_billing on time_entries for update
  using (
    is_studio_member(studio_id)
    and (is_studio_owner(studio_id) or has_permission(studio_id, 'edit_invoices'))
  )
  with check (
    is_studio_member(studio_id)
    and (is_studio_owner(studio_id) or has_permission(studio_id, 'edit_invoices'))
  );

create unique index if not exists one_running_timer_per_user
  on time_entries (user_id)
  where ended_at is null;

commit;

-- ════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- ════════════════════════════════════════════════════════════════

-- 1. Policies on time_entries (expect 7: the prior 6 + time_update_billing).
select policyname, cmd from pg_policies
  where tablename = 'time_entries' order by policyname;

-- 2. The partial unique index exists.
select indexname from pg_indexes
  where tablename = 'time_entries' and indexname = 'one_running_timer_per_user';

-- 3. No user has two running timers (must be 0 rows or the index wouldn't build).
select user_id, count(*) from time_entries
  where ended_at is null group by user_id having count(*) > 1;
