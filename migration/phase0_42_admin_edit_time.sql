-- Admin edit of team members' time entries.
--
-- Let studio OWNERS edit/delete any team member's UNBILLED time entry — e.g.,
-- fix a timer someone forgot to stop, correct a duration, reassign a project.
-- Non-owners are unchanged: still limited to their OWN unbilled entries.
--
-- Billed entries stay locked for everyone (they're on sent invoices; §3 rule).
-- SELECT is unchanged (owners already see all studio entries). INSERT is
-- unchanged (each person still logs only their own; on-behalf logging is not
-- part of this). Idempotent — drops + recreates the two policies.

drop policy if exists time_update on time_entries;
create policy time_update on time_entries for update
  using      (is_studio_member(studio_id) and status = 'unbilled' and (user_id = auth.uid() or is_studio_owner(studio_id)))
  with check (is_studio_member(studio_id) and status = 'unbilled' and (user_id = auth.uid() or is_studio_owner(studio_id)));

drop policy if exists time_delete on time_entries;
create policy time_delete on time_entries for delete
  using (is_studio_member(studio_id) and status = 'unbilled' and (user_id = auth.uid() or is_studio_owner(studio_id)));
