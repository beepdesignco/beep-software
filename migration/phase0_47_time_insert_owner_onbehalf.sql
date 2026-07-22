-- Let a studio OWNER log time on behalf of a team member (attribute a new time
-- entry to another member's user_id). Non-owners can still only insert their own
-- entries (user_id = auth.uid()) — the app also locks a non-owner's Log Time
-- "Person" field to themselves. Combined with phase0_42 (owner can update/delete
-- any unbilled entry), this lets the admin both create and reassign attribution.

drop policy if exists time_insert on time_entries;
create policy time_insert on time_entries for insert
  with check (
    is_studio_member(studio_id)
    and (user_id = auth.uid() or is_studio_owner(studio_id))
  );
