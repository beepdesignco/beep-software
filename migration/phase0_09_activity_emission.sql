-- Phase 0, step 9 — activity_entries system event emission.
--
-- Problem: the activity_entries RLS policy `activity_insert` rejects inserts
-- where source != 'user' (deliberate — keeps user-space code from forging
-- system events). So system events can't be written at all without an
-- elevated path.
--
-- Solution: a SECURITY DEFINER function that inserts a locked system event
-- after validating the caller is a member of the target studio. The actor
-- (created_by / author_user_id) is always auth.uid() — not an argument —
-- so the caller can't spoof another user.
--
-- event_type naming convention: entity.action
--   invoice.sent, invoice.paid, invoice.cancelled
--   item.status_changed
--   po.status_changed
--   rfi.opened, rfi.closed
--   submittal.signed, submittal.completed
--
-- Idempotent.

create or replace function emit_system_event(
  p_studio_id   uuid,
  p_project_id  uuid,
  p_entity_type text,
  p_entity_id   uuid,
  p_event_type  text,
  p_body        text,
  p_payload     jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
begin
  if v_actor is null then
    raise exception 'emit_system_event: no authenticated user'
      using errcode = '42501';
  end if;
  if not public.is_studio_member(p_studio_id) then
    raise exception 'emit_system_event: caller is not a member of studio %', p_studio_id
      using errcode = '42501';
  end if;

  insert into public.activity_entries (
    studio_id, entity_type, entity_id,
    parent_type, parent_id,
    author_user_id,
    text, mentions,
    source, is_locked, event_type, payload
  ) values (
    p_studio_id, p_entity_type, p_entity_id,
    -- Parent link: if a project id was passed and the entity isn't a project,
    -- record the project as the parent so per-project queries find this row.
    case when p_project_id is not null and p_entity_type <> 'project' then 'project' else null end,
    case when p_project_id is not null and p_entity_type <> 'project' then p_project_id else null end,
    v_actor,
    coalesce(p_body, ''),
    '{}'::uuid[],
    'system', true, p_event_type, coalesce(p_payload, '{}'::jsonb)
  )
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function emit_system_event(uuid, uuid, text, uuid, text, text, jsonb)
  to authenticated;

-- Verification — run after applying to confirm the function exists and is granted.
select proname, prosecdef as is_security_definer
  from pg_proc
  where proname = 'emit_system_event';

select has_function_privilege('authenticated', 'emit_system_event(uuid, uuid, text, uuid, text, text, jsonb)', 'execute') as authenticated_can_execute;
