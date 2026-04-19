-- BEEP HQ — Row-Level Security policies
-- Run AFTER schema.sql. Safe to re-run: uses drop if exists + create.
-- Model: every table is scoped to a studio. Users see/write only their own studio's data.
-- Some tables have additional permission gates (e.g. financials).

-- ════════════════════════════════════════════════════════════════
-- HELPER FUNCTIONS
-- SECURITY DEFINER so they can read studio_members without being blocked by RLS on that table.
-- STABLE so Postgres can cache within a single query.
-- ════════════════════════════════════════════════════════════════

-- IMPORTANT: security definer functions need an explicit search_path, schema-qualified table references,
-- and explicit grant execute to authenticated/anon roles, or Supabase/PostgREST will silently fail to call them.

create or replace function is_studio_member(target_studio uuid)
returns boolean language sql security definer stable
set search_path = public, auth as $$
  select exists (
    select 1 from public.studio_members
    where studio_id = target_studio
      and user_id = auth.uid()
      and accepted_at is not null
  );
$$;

create or replace function is_studio_owner(target_studio uuid)
returns boolean language sql security definer stable
set search_path = public, auth as $$
  select exists (
    select 1 from public.studio_members
    where studio_id = target_studio
      and user_id = auth.uid()
      and role = 'owner'
  );
$$;

-- perm values: 'view_financials' | 'record_payments' | 'send_invoices' | 'manage_expenses' | 'manage_members'
create or replace function has_permission(target_studio uuid, perm text)
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

-- Lookup a studio_id by a child entity's id, for policies on child tables
create or replace function studio_of_invoice(inv_id uuid)
returns uuid language sql security definer stable
set search_path = public, auth as $$
  select studio_id from public.invoices where id = inv_id;
$$;

create or replace function studio_of_project(proj_id uuid)
returns uuid language sql security definer stable
set search_path = public, auth as $$
  select studio_id from public.projects where id = proj_id;
$$;

create or replace function studio_of_space(space_id uuid)
returns uuid language sql security definer stable
set search_path = public, auth as $$
  select p.studio_id
  from public.proposal_spaces s
  join public.projects p on p.id = s.project_id
  where s.id = space_id;
$$;

create or replace function studio_of_item(item_id uuid)
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

-- ════════════════════════════════════════════════════════════════
-- ENABLE RLS
-- ════════════════════════════════════════════════════════════════

alter table studios               enable row level security;
alter table studio_members        enable row level security;
alter table clients               enable row level security;
alter table contacts              enable row level security;
alter table projects              enable row level security;
alter table project_contacts      enable row level security;
alter table proposal_spaces       enable row level security;
alter table proposal_items        enable row level security;
alter table proposal_components   enable row level security;
alter table estimates             enable row level security;
alter table invoices              enable row level security;
alter table invoice_line_items    enable row level security;
alter table invoice_payments      enable row level security;
alter table expenses              enable row level security;
alter table documents             enable row level security;
alter table document_versions     enable row level security;
alter table tasks                 enable row level security;
alter table task_notes            enable row level security;
alter table activity_entries      enable row level security;
alter table notifications         enable row level security;
alter table time_entries          enable row level security;

-- ════════════════════════════════════════════════════════════════
-- STUDIOS
-- ════════════════════════════════════════════════════════════════

drop policy if exists studios_select on studios;
drop policy if exists studios_insert on studios;
drop policy if exists studios_update on studios;

create policy studios_select on studios for select
  using (is_studio_member(id));

create policy studios_insert on studios for insert
  with check (auth.uid() is not null and auth.uid() = owner_user_id);

create policy studios_update on studios for update
  using (is_studio_owner(id))
  with check (is_studio_owner(id));

-- No delete policy → deletion requires service_role.

-- ════════════════════════════════════════════════════════════════
-- STUDIO_MEMBERS
-- ════════════════════════════════════════════════════════════════

drop policy if exists members_select      on studio_members;
drop policy if exists members_self_select on studio_members;
drop policy if exists members_team_select on studio_members;
drop policy if exists members_insert      on studio_members;
drop policy if exists members_update      on studio_members;
drop policy if exists members_delete      on studio_members;

-- You can always see your own membership row — critical for login lookup, doesn't depend on helper functions.
create policy members_self_select on studio_members for select
  using (user_id = auth.uid());

-- You can see teammates in studios you're a member of.
create policy members_team_select on studio_members for select
  using (is_studio_member(studio_id));

-- Owner invites; also allow a user inserting their own owner row when creating a new studio
create policy members_insert on studio_members for insert
  with check (
    is_studio_owner(studio_id)
    or (user_id = auth.uid() and role = 'owner')
  );

-- Owner can update any member; member can update their own profile fields (enforced in app layer)
create policy members_update on studio_members for update
  using (is_studio_owner(studio_id) or user_id = auth.uid())
  with check (is_studio_owner(studio_id) or user_id = auth.uid());

-- Only owner deletes members; can't delete self
create policy members_delete on studio_members for delete
  using (is_studio_owner(studio_id) and user_id <> auth.uid());

-- ════════════════════════════════════════════════════════════════
-- CLIENTS / CONTACTS / PROJECTS (studio-scoped, all members can CRUD)
-- ════════════════════════════════════════════════════════════════

-- Macro: standard studio-scoped policies
-- (Not a real macro — SQL doesn't have those. We repeat the pattern.)

-- clients
drop policy if exists clients_all on clients;
create policy clients_all on clients for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

-- contacts
drop policy if exists contacts_all on contacts;
create policy contacts_all on contacts for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

-- projects
drop policy if exists projects_all on projects;
create policy projects_all on projects for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

-- project_contacts (child of projects)
drop policy if exists project_contacts_all on project_contacts;
create policy project_contacts_all on project_contacts for all
  using (is_studio_member(studio_of_project(project_id)))
  with check (is_studio_member(studio_of_project(project_id)));

-- ════════════════════════════════════════════════════════════════
-- PROPOSALS (spaces → items → components)
-- ════════════════════════════════════════════════════════════════

drop policy if exists spaces_all on proposal_spaces;
create policy spaces_all on proposal_spaces for all
  using (is_studio_member(studio_of_project(project_id)))
  with check (is_studio_member(studio_of_project(project_id)));

drop policy if exists items_all on proposal_items;
create policy items_all on proposal_items for all
  using (is_studio_member(studio_of_space(space_id)))
  with check (is_studio_member(studio_of_space(space_id)));

drop policy if exists components_all on proposal_components;
create policy components_all on proposal_components for all
  using (is_studio_member(studio_of_item(item_id)))
  with check (is_studio_member(studio_of_item(item_id)));

drop policy if exists estimates_all on estimates;
create policy estimates_all on estimates for all
  using (is_studio_member(studio_of_project(project_id)))
  with check (is_studio_member(studio_of_project(project_id)));

-- ════════════════════════════════════════════════════════════════
-- INVOICES (gated on can_view_financials)
-- ════════════════════════════════════════════════════════════════

drop policy if exists invoices_select on invoices;
drop policy if exists invoices_modify on invoices;

create policy invoices_select on invoices for select
  using (has_permission(studio_id, 'view_financials'));

-- Any member with financial access can create/edit; dedicated send/record gates happen in app layer
create policy invoices_modify on invoices for all
  using (has_permission(studio_id, 'view_financials'))
  with check (has_permission(studio_id, 'view_financials'));

drop policy if exists inv_lines_all on invoice_line_items;
create policy inv_lines_all on invoice_line_items for all
  using (has_permission(studio_of_invoice(invoice_id), 'view_financials'))
  with check (has_permission(studio_of_invoice(invoice_id), 'view_financials'));

drop policy if exists inv_payments_select on invoice_payments;
drop policy if exists inv_payments_modify on invoice_payments;

create policy inv_payments_select on invoice_payments for select
  using (has_permission(studio_of_invoice(invoice_id), 'view_financials'));

-- Payments write requires can_record_payments (owner always has it)
create policy inv_payments_modify on invoice_payments for all
  using (has_permission(studio_of_invoice(invoice_id), 'record_payments'))
  with check (has_permission(studio_of_invoice(invoice_id), 'record_payments'));

-- ════════════════════════════════════════════════════════════════
-- EXPENSES (gated on can_view_financials; edit gated on can_manage_expenses)
-- ════════════════════════════════════════════════════════════════

drop policy if exists expenses_select on expenses;
drop policy if exists expenses_modify on expenses;

create policy expenses_select on expenses for select
  using (has_permission(studio_id, 'view_financials'));

create policy expenses_modify on expenses for all
  using (has_permission(studio_id, 'view_financials'))
  with check (has_permission(studio_id, 'view_financials'));

-- ════════════════════════════════════════════════════════════════
-- DOCUMENTS
-- ════════════════════════════════════════════════════════════════

drop policy if exists documents_all on documents;
create policy documents_all on documents for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

drop policy if exists doc_versions_all on document_versions;
create policy doc_versions_all on document_versions for all
  using (
    exists (select 1 from documents d where d.id = document_id and is_studio_member(d.studio_id))
  )
  with check (
    exists (select 1 from documents d where d.id = document_id and is_studio_member(d.studio_id))
  );

-- ════════════════════════════════════════════════════════════════
-- TASKS
-- ════════════════════════════════════════════════════════════════

drop policy if exists tasks_all on tasks;
create policy tasks_all on tasks for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

drop policy if exists task_notes_all on task_notes;
create policy task_notes_all on task_notes for all
  using (
    exists (select 1 from tasks t where t.id = task_id and is_studio_member(t.studio_id))
  )
  with check (
    exists (select 1 from tasks t where t.id = task_id and is_studio_member(t.studio_id))
  );

-- ════════════════════════════════════════════════════════════════
-- ACTIVITY & NOTIFICATIONS
-- ════════════════════════════════════════════════════════════════

drop policy if exists activity_all on activity_entries;
create policy activity_all on activity_entries for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

drop policy if exists notifications_select on notifications;
drop policy if exists notifications_insert on notifications;
drop policy if exists notifications_update on notifications;

create policy notifications_select on notifications for select
  using (recipient_user_id = auth.uid());

-- Any studio member can create notifications for others in the same studio
create policy notifications_insert on notifications for insert
  with check (is_studio_member(studio_id));

-- Only recipient can mark own notifications read
create policy notifications_update on notifications for update
  using (recipient_user_id = auth.uid())
  with check (recipient_user_id = auth.uid());

-- ════════════════════════════════════════════════════════════════
-- TIME ENTRIES
-- Users can see/edit their own entries; owner can see all in studio.
-- ════════════════════════════════════════════════════════════════

drop policy if exists time_select on time_entries;
drop policy if exists time_modify on time_entries;

create policy time_select on time_entries for select
  using (user_id = auth.uid() or is_studio_owner(studio_id));

create policy time_modify on time_entries for all
  using (user_id = auth.uid() and is_studio_member(studio_id))
  with check (user_id = auth.uid() and is_studio_member(studio_id));
