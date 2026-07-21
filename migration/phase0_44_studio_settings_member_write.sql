-- Let studio MEMBERS (not just owners) update the studios row.
--
-- Shared taxonomy lives in studios.settings (jsonb): vendor/brand categories,
-- vendor types, qty units, status config, etc. The studios_update policy was
-- owner-only, so when a member (e.g. a project coordinator) added a vendor or
-- brand category the app's save was SILENTLY rejected by RLS — the change never
-- persisted, so no one else saw it and it vanished on reload.
--
-- Members can now update the row so those shared lists save for everyone.
-- Ownership is frozen against non-owner writes by a trigger below, so a member
-- can't reassign the studio to themselves. (Finer-grained, column-level control
-- over the settings blob — e.g. keeping tax settings owner-only — is a future
-- refactor: move shared lists into their own table. For now the app UI gates
-- who can open tax/project settings; this RLS change only unblocks saving.)

drop policy if exists studios_update on studios;
create policy studios_update on studios for update
  using (is_studio_member(id))
  with check (is_studio_member(id));

-- Freeze owner_user_id: only the current owner may change ownership.
create or replace function protect_studio_owner()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if NEW.owner_user_id is distinct from OLD.owner_user_id and not is_studio_owner(OLD.id) then
    raise exception 'Only the owner can change studio ownership' using errcode = '42501';
  end if;
  return NEW;
end $$;

drop trigger if exists trg_protect_studio_owner on studios;
create trigger trg_protect_studio_owner
  before update on studios
  for each row execute function protect_studio_owner();
