-- Fix: simplify studio_members RLS so the login lookup works reliably,
-- and harden helper functions (set search_path, grant execute to authenticated).

-- ── Re-enable RLS (was temporarily disabled for diagnosis)
alter table studio_members enable row level security;

-- ── Rebuild helper functions with explicit search_path + grants
drop function if exists is_studio_member(uuid) cascade;
drop function if exists is_studio_owner(uuid) cascade;
drop function if exists has_permission(uuid, text) cascade;
drop function if exists studio_of_invoice(uuid) cascade;
drop function if exists studio_of_project(uuid) cascade;
drop function if exists studio_of_space(uuid) cascade;
drop function if exists studio_of_item(uuid) cascade;

create function is_studio_member(target_studio uuid)
returns boolean language sql security definer stable
set search_path = public, auth as $$
  select exists (
    select 1 from public.studio_members
    where studio_id = target_studio
      and user_id = auth.uid()
      and accepted_at is not null
  );
$$;

create function is_studio_owner(target_studio uuid)
returns boolean language sql security definer stable
set search_path = public, auth as $$
  select exists (
    select 1 from public.studio_members
    where studio_id = target_studio
      and user_id = auth.uid()
      and role = 'owner'
  );
$$;

create function has_permission(target_studio uuid, perm text)
returns boolean language sql security definer stable
set search_path = public, auth as $$
  select exists (
    select 1 from public.studio_members
    where studio_id = target_studio
      and user_id = auth.uid()
      and (
        role = 'owner'
        or (perm = 'view_financials'  and can_view_financials)
        or (perm = 'record_payments'  and can_record_payments)
        or (perm = 'send_invoices'    and can_send_invoices)
        or (perm = 'manage_expenses'  and can_manage_expenses)
        or (perm = 'manage_members'   and can_manage_members)
      )
  );
$$;

create function studio_of_invoice(inv_id uuid)
returns uuid language sql security definer stable
set search_path = public, auth as $$
  select studio_id from public.invoices where id = inv_id;
$$;

create function studio_of_project(proj_id uuid)
returns uuid language sql security definer stable
set search_path = public, auth as $$
  select studio_id from public.projects where id = proj_id;
$$;

create function studio_of_space(space_id uuid)
returns uuid language sql security definer stable
set search_path = public, auth as $$
  select p.studio_id
  from public.proposal_spaces s
  join public.projects p on p.id = s.project_id
  where s.id = space_id;
$$;

create function studio_of_item(item_id uuid)
returns uuid language sql security definer stable
set search_path = public, auth as $$
  select p.studio_id
  from public.proposal_items i
  join public.proposal_spaces s on s.id = i.space_id
  join public.projects p on p.id = s.project_id
  where i.id = item_id;
$$;

grant execute on function is_studio_member(uuid), is_studio_owner(uuid), has_permission(uuid, text),
  studio_of_invoice(uuid), studio_of_project(uuid), studio_of_space(uuid), studio_of_item(uuid)
  to authenticated, anon;

-- ── Rebuild studio_members policies
drop policy if exists members_select      on studio_members;
drop policy if exists members_self_select on studio_members;
drop policy if exists members_team_select on studio_members;
drop policy if exists members_insert      on studio_members;
drop policy if exists members_update      on studio_members;
drop policy if exists members_delete      on studio_members;

-- You can always see your own membership row (critical for login flow).
create policy members_self_select on studio_members for select
  using (user_id = auth.uid());

-- You can see teammates in the same studio (uses helper; this is the feature we had trouble with — kept as additive).
create policy members_team_select on studio_members for select
  using (is_studio_member(studio_id));

-- Insert: studio owner invites, or user creating their own owner row for a new studio
create policy members_insert on studio_members for insert
  with check (
    is_studio_owner(studio_id)
    or (user_id = auth.uid() and role = 'owner')
  );

-- Update: owner updates anyone, member updates their own profile
create policy members_update on studio_members for update
  using (is_studio_owner(studio_id) or user_id = auth.uid())
  with check (is_studio_owner(studio_id) or user_id = auth.uid());

-- Delete: owner removes others; can't remove self
create policy members_delete on studio_members for delete
  using (is_studio_owner(studio_id) and user_id <> auth.uid());
