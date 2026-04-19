-- BEEP HQ — Supabase schema
-- Multi-tenant from day one: every table carries studio_id so adding other studios later requires zero data migration.
-- Soft-delete via deleted_at. Audit trail via created_by_user_id / updated_by_user_id and timestamps.
-- Enable pgcrypto for gen_random_uuid() and uuid-ossp if needed.

create extension if not exists "pgcrypto";

-- ════════════════════════════════════════════════════════════════
-- IDENTITY
-- ════════════════════════════════════════════════════════════════

create table studios (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  owner_user_id   uuid not null references auth.users(id),
  studio_info     jsonb not null default '{}'::jsonb,  -- name, address1, address2, phone, email, website (for PDFs)
  settings        jsonb not null default '{}'::jsonb,  -- qty_units, task_statuses, payment_cards, status_colors, etc.
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table studio_members (
  id                     uuid primary key default gen_random_uuid(),
  studio_id              uuid not null references studios(id) on delete cascade,
  user_id                uuid not null references auth.users(id) on delete cascade,
  role                   text not null check (role in ('owner','member')),
  display_name           text,
  job_title              text,
  phone                  text,
  -- Granular permission flags (owner implicitly has all; members checked explicitly)
  can_view_financials    boolean not null default true,
  can_record_payments    boolean not null default false,
  can_send_invoices      boolean not null default false,
  can_manage_expenses    boolean not null default false,
  can_manage_members     boolean not null default false,
  invited_at             timestamptz,
  accepted_at            timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (studio_id, user_id)
);
create index idx_studio_members_studio on studio_members(studio_id);
create index idx_studio_members_user on studio_members(user_id);
-- Enforce exactly one owner per studio
create unique index uniq_one_owner_per_studio on studio_members(studio_id) where role = 'owner';

-- ════════════════════════════════════════════════════════════════
-- CLIENTS & CONTACTS
-- ════════════════════════════════════════════════════════════════

create table clients (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  name                text not null,
  email               text,
  phone               text,
  address             text,
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  created_by_user_id  uuid references auth.users(id),
  updated_by_user_id  uuid references auth.users(id)
);
create index idx_clients_studio on clients(studio_id) where deleted_at is null;

create table contacts (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  client_id           uuid references clients(id) on delete set null,  -- nullable; contacts can be independent
  name                text not null,
  email               text,
  phone               text,
  company             text,
  role                text,
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  created_by_user_id  uuid references auth.users(id),
  updated_by_user_id  uuid references auth.users(id)
);
create index idx_contacts_studio on contacts(studio_id) where deleted_at is null;
create index idx_contacts_client on contacts(client_id) where deleted_at is null;

-- ════════════════════════════════════════════════════════════════
-- PROJECTS
-- ════════════════════════════════════════════════════════════════

create table projects (
  id                    uuid primary key default gen_random_uuid(),
  studio_id             uuid not null references studios(id) on delete cascade,
  client_id             uuid references clients(id) on delete set null,
  name                  text not null,
  stage                 text,                    -- kanban stage
  type                  text,                    -- 'residential' | 'commercial' | etc.
  street                text,
  city                  text,
  state                 text,
  zip                   text,
  markup_pct            numeric(6,2) default 25,
  tax_rate              numeric(6,2) default 0,
  tax_freight           boolean default false,
  -- Address book (receiver/contractor/architect/landscape_architect). jsonb to preserve current shape.
  address_book          jsonb not null default '{}'::jsonb,
  quick_references      jsonb not null default '[]'::jsonb,  -- drag-and-drop list on Overview
  settings              jsonb not null default '{}'::jsonb,  -- misc project settings
  notifications         jsonb not null default '[]'::jsonb,  -- legacy in-project notifications list (invoice_sent, etc.)
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,
  created_by_user_id    uuid references auth.users(id),
  updated_by_user_id    uuid references auth.users(id)
);
create index idx_projects_studio on projects(studio_id) where deleted_at is null;
create index idx_projects_client on projects(client_id) where deleted_at is null;

-- Junction: project ↔ contacts with linked role + star flag
create table project_contacts (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null references projects(id) on delete cascade,
  contact_id  uuid not null references contacts(id) on delete cascade,
  role        text,
  starred     boolean not null default false,
  notes       text,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  unique (project_id, contact_id, role)
);
create index idx_project_contacts_project on project_contacts(project_id);

-- ════════════════════════════════════════════════════════════════
-- PROPOSALS
-- One proposal per project. Proposal is just a collection of spaces.
-- ════════════════════════════════════════════════════════════════

create table proposal_spaces (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null references projects(id) on delete cascade,
  name        text not null,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);
create index idx_spaces_project on proposal_spaces(project_id) where deleted_at is null;

create table proposal_items (
  id                    uuid primary key default gen_random_uuid(),
  space_id              uuid not null references proposal_spaces(id) on delete cascade,
  type                  text not null check (type in ('readymade','openline','constructed')),
  name                  text not null,
  item_code             text,
  contact               text,
  room                  text,
  status                text not null default 'proposed',
  status_flags          jsonb not null default '[]'::jsonb,
  -- Proposal side pricing (numeric; JS parses via parse$() on save, formats via fmt() on display)
  net_price             numeric(12,2),
  qty                   numeric(10,2) default 1,
  qty_unit              text,
  category              text,
  notes                 text,
  description           text,
  due_date              date,
  invoice_phase         text,
  allowance             boolean not null default false,
  tax_exempt            boolean not null default false,
  bill_cost_only        boolean not null default false,
  adjust_markup         numeric(6,2),
  group_components      boolean not null default false,
  additional_charges    jsonb not null default '[]'::jsonb,  -- proposal-time charges (readymade)
  -- Actual cost tracking (PM side)
  cost_actual           numeric(12,2),
  actual_freight        numeric(12,2),
  additional_costs      jsonb not null default '[]'::jsonb,  -- [{id, name, amount}] amounts stored as numbers
  -- Cross-refs (maintained for current automations)
  proposal_item_origin  uuid,                                -- if this was auto-generated from an invoice
  invoice_ids           uuid[] not null default '{}',        -- invoices this item appears on
  expense_id            uuid,                                -- if this item was created from an expense
  invoice_line_id       uuid,
  invoice_number        text,
  -- Attachments + activity
  files                 jsonb not null default '[]'::jsonb,  -- [{id, name, storage_path, size, type}]
  links                 jsonb not null default '[]'::jsonb,
  tracking_numbers      jsonb not null default '[]'::jsonb,
  activity_log          jsonb not null default '[]'::jsonb,  -- legacy inline log; new entries go to activity_entries
  sort_order            integer not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,
  created_by_user_id    uuid references auth.users(id),
  updated_by_user_id    uuid references auth.users(id)
);
create index idx_items_space on proposal_items(space_id) where deleted_at is null;
create index idx_items_expense on proposal_items(expense_id) where expense_id is not null;

create table proposal_components (
  id                    uuid primary key default gen_random_uuid(),
  item_id               uuid not null references proposal_items(id) on delete cascade,
  name                  text,
  component_type        text,                                  -- 'base' | 'face' | 'workroom' | ...
  contact               text,
  net_cost              numeric(12,2),
  qty                   numeric(10,2) default 1,
  qty_unit              text,
  status                text default 'proposed',
  due_date              date,
  invoice_phase         text,
  description           text,
  note                  text,
  allowance             boolean not null default false,
  tax_exempt            boolean not null default false,
  bill_cost_only        boolean not null default false,
  adjust_markup         numeric(6,2),
  -- Actual cost tracking
  cost_actual           numeric(12,2),
  actual_freight        numeric(12,2),
  additional_costs      jsonb not null default '[]'::jsonb,
  files                 jsonb not null default '[]'::jsonb,
  links                 jsonb not null default '[]'::jsonb,
  tracking_numbers      jsonb not null default '[]'::jsonb,
  activity_log          jsonb not null default '[]'::jsonb,
  sort_order            integer not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz
);
create index idx_components_item on proposal_components(item_id) where deleted_at is null;

-- Estimates (proposal-level totals with freight/tariffs/etc.)
create table estimates (
  id                   uuid primary key default gen_random_uuid(),
  project_id           uuid not null references projects(id) on delete cascade,
  name                 text,
  freight              numeric(12,2) default 0,
  freight_taxable      boolean default false,
  hours                numeric(8,2) default 0,
  hourly_rate          numeric(10,2) default 0,
  receiving            numeric(12,2) default 0,
  storage              numeric(12,2) default 0,
  tariffs_pct          numeric(6,2) default 0,
  custom_lines         jsonb not null default '[]'::jsonb,  -- [{name, amount, taxable}]
  snapshot             jsonb not null default '{}'::jsonb,  -- cached subtotal/tax/total at print time
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz,
  created_by_user_id   uuid references auth.users(id)
);
create index idx_estimates_project on estimates(project_id) where deleted_at is null;

-- ════════════════════════════════════════════════════════════════
-- INVOICES
-- ════════════════════════════════════════════════════════════════

create table invoices (
  id                    uuid primary key default gen_random_uuid(),
  studio_id             uuid not null references studios(id) on delete cascade,
  project_id            uuid references projects(id) on delete set null,
  client_id             uuid references clients(id) on delete set null,
  number                text not null,                 -- 'BE-100'
  type                  text,                          -- 'phased' | 'monthly' | 'standalone' | 'design_fee'
  status                text not null default 'draft'  -- 'draft'|'sent'|'partial'|'paid'|'cancelled'
                        check (status in ('draft','sent','partial','paid','cancelled')),
  phase                 text,
  sent_date             date,
  due_date              date,
  notes                 text,
  -- Totals (cached for reporting)
  subtotal              numeric(12,2) not null default 0,
  freight               numeric(12,2) not null default 0,
  freight_taxable       boolean not null default false,
  discount_type         text,
  discount_value        numeric(10,2) default 0,
  discount              numeric(12,2) not null default 0,
  cc_fee_pct            numeric(6,2) default 0,
  cc_fee                numeric(12,2) not null default 0,
  tax_rate              numeric(6,2) default 0,
  tax                   numeric(12,2) not null default 0,
  total                 numeric(12,2) not null default 0,
  files                 jsonb not null default '[]'::jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,
  created_by_user_id    uuid references auth.users(id),
  updated_by_user_id    uuid references auth.users(id),
  unique (studio_id, number)
);
create index idx_invoices_studio on invoices(studio_id) where deleted_at is null;
create index idx_invoices_project on invoices(project_id) where deleted_at is null;
create index idx_invoices_status on invoices(studio_id, status) where deleted_at is null;

create table invoice_line_items (
  id                    uuid primary key default gen_random_uuid(),
  invoice_id            uuid not null references invoices(id) on delete cascade,
  name                  text,
  qty                   numeric(10,2) not null default 1,
  price                 numeric(12,2) not null default 0,
  taxable               boolean not null default false,
  track_in_pm           boolean not null default false,
  manual                boolean not null default false,
  proposal_item_id      uuid references proposal_items(id) on delete set null,
  expense_id            uuid,                              -- FK added later (expenses table declared below)
  sort_order            integer not null default 0
);
create index idx_inv_lines_invoice on invoice_line_items(invoice_id);
create index idx_inv_lines_proposal_item on invoice_line_items(proposal_item_id) where proposal_item_id is not null;
create index idx_inv_lines_expense on invoice_line_items(expense_id) where expense_id is not null;

create table invoice_payments (
  id                    uuid primary key default gen_random_uuid(),
  invoice_id            uuid not null references invoices(id) on delete cascade,
  date                  date not null,
  amount                numeric(12,2) not null,
  method                text,
  notes                 text,
  -- Stripe integration (phase 2)
  stripe_payment_intent text,
  stripe_charge_id      text,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid references auth.users(id)
);
create index idx_inv_payments_invoice on invoice_payments(invoice_id);

-- ════════════════════════════════════════════════════════════════
-- EXPENSES
-- ════════════════════════════════════════════════════════════════

create table expenses (
  id                       uuid primary key default gen_random_uuid(),
  studio_id                uuid not null references studios(id) on delete cascade,
  project_id               uuid references projects(id) on delete set null,
  name                     text not null,
  cost                     numeric(12,2),
  date                     date,
  card                     text,
  expense_type             text not null check (expense_type in ('billable','passthrough','nonbillable')),
  category                 text,
  notes                    text,
  track_in_pm              boolean not null default false,
  receipt_path             text,                                -- Supabase Storage path
  resolved                 boolean not null default false,
  status                   text,                                -- 'invoiced' | 'client_payment_received' | null
  resolved_invoice_id      uuid references invoices(id) on delete set null,
  resolved_invoice_number  text,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  deleted_at               timestamptz,
  created_by_user_id       uuid references auth.users(id),
  updated_by_user_id       uuid references auth.users(id)
);
create index idx_expenses_studio on expenses(studio_id) where deleted_at is null;
create index idx_expenses_project on expenses(project_id) where deleted_at is null;

-- Back-reference now that expenses table exists
alter table invoice_line_items add constraint fk_inv_lines_expense
  foreign key (expense_id) references expenses(id) on delete set null;

-- ════════════════════════════════════════════════════════════════
-- DOCUMENTS
-- Schedules (Material, Paint/Paper, Furniture, etc.) with versioning.
-- ════════════════════════════════════════════════════════════════

create table documents (
  id                    uuid primary key default gen_random_uuid(),
  studio_id             uuid not null references studios(id) on delete cascade,
  project_id            uuid not null references projects(id) on delete cascade,
  template_id           text not null,                         -- 'material_schedule', 'paint_paper_schedule', etc.
  title                 text not null,
  current_version_id    uuid,                                  -- FK added below
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,
  created_by_user_id    uuid references auth.users(id)
);
create index idx_documents_project on documents(project_id) where deleted_at is null;

create table document_versions (
  id                    uuid primary key default gen_random_uuid(),
  document_id           uuid not null references documents(id) on delete cascade,
  version_letter        text not null,                         -- A, B, C...
  revision_number       integer not null default 0,
  data                  jsonb not null default '{}'::jsonb,    -- entire schedule content (rooms, swatches, etc.)
  files                 jsonb not null default '[]'::jsonb,
  created_at            timestamptz not null default now(),
  created_by_user_id    uuid references auth.users(id),
  unique (document_id, version_letter, revision_number)
);
create index idx_doc_versions_document on document_versions(document_id);

alter table documents add constraint fk_documents_current_version
  foreign key (current_version_id) references document_versions(id) on delete set null;

-- ════════════════════════════════════════════════════════════════
-- TASKS (future UI; schema ready now)
-- ════════════════════════════════════════════════════════════════

create table tasks (
  id                    uuid primary key default gen_random_uuid(),
  studio_id             uuid not null references studios(id) on delete cascade,
  project_id            uuid references projects(id) on delete cascade,
  title                 text not null,
  description           text,
  assigned_to_user_id   uuid references auth.users(id),
  status                text not null default 'todo',
  due_date              date,
  completed_at          timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,
  created_by_user_id    uuid references auth.users(id),
  updated_by_user_id    uuid references auth.users(id)
);
create index idx_tasks_studio on tasks(studio_id) where deleted_at is null;
create index idx_tasks_assignee on tasks(assigned_to_user_id) where deleted_at is null and completed_at is null;
create index idx_tasks_project on tasks(project_id) where deleted_at is null;

create table task_notes (
  id                   uuid primary key default gen_random_uuid(),
  task_id              uuid not null references tasks(id) on delete cascade,
  author_user_id       uuid references auth.users(id),
  text                 text not null,
  mentions             uuid[] not null default '{}',
  created_at           timestamptz not null default now()
);
create index idx_task_notes_task on task_notes(task_id);

-- ════════════════════════════════════════════════════════════════
-- ACTIVITY & COMMENTS
-- Unified table for notes/comments across items, components, invoices, expenses, projects.
-- Polymorphic via (entity_type, entity_id) pair.
-- ════════════════════════════════════════════════════════════════

create table activity_entries (
  id                uuid primary key default gen_random_uuid(),
  studio_id         uuid not null references studios(id) on delete cascade,
  entity_type       text not null,                            -- 'proposal_item' | 'proposal_component' | 'invoice' | 'expense' | 'project' | 'task'
  entity_id         uuid not null,
  parent_type       text,                                     -- e.g. 'proposal_item' when entity is a component
  parent_id         uuid,
  author_user_id    uuid references auth.users(id),
  text              text not null,
  mentions          uuid[] not null default '{}',             -- array of mentioned user_ids
  created_at        timestamptz not null default now(),
  deleted_at        timestamptz
);
create index idx_activity_entity on activity_entries(entity_type, entity_id) where deleted_at is null;
create index idx_activity_studio on activity_entries(studio_id, created_at desc) where deleted_at is null;

-- ════════════════════════════════════════════════════════════════
-- NOTIFICATIONS
-- @-mentions, task assignments, invoice events, etc.
-- ════════════════════════════════════════════════════════════════

create table notifications (
  id                uuid primary key default gen_random_uuid(),
  studio_id         uuid not null references studios(id) on delete cascade,
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  type              text not null,                            -- 'mention' | 'task_assigned' | 'invoice_paid' | 'comment' | ...
  payload           jsonb not null default '{}'::jsonb,       -- { commentId, invoiceNumber, ... }
  link_entity_type  text,                                     -- for click-through
  link_entity_id    uuid,
  message           text,                                     -- pre-rendered display text
  read_at           timestamptz,
  created_at        timestamptz not null default now()
);
create index idx_notifications_recipient on notifications(recipient_user_id, read_at, created_at desc);
create index idx_notifications_studio on notifications(studio_id);

-- ════════════════════════════════════════════════════════════════
-- TIME TRACKER
-- ════════════════════════════════════════════════════════════════

create table time_entries (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  user_id             uuid not null references auth.users(id) on delete cascade,
  project_id          uuid references projects(id) on delete set null,
  task_id             uuid references tasks(id) on delete set null,
  description         text,
  started_at          timestamptz not null,
  ended_at            timestamptz,
  duration_seconds    integer,                              -- cached: null while running, set on stop
  billable            boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index idx_time_user on time_entries(user_id, started_at desc);
create index idx_time_project on time_entries(project_id) where project_id is not null;

-- ════════════════════════════════════════════════════════════════
-- AUTO-UPDATE updated_at TRIGGERS
-- ════════════════════════════════════════════════════════════════

create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Attach to every table with updated_at
do $$
declare t text;
begin
  for t in
    select unnest(array[
      'studios','studio_members','clients','contacts','projects',
      'proposal_spaces','proposal_items','proposal_components','estimates',
      'invoices','expenses','documents','tasks','time_entries'
    ])
  loop
    execute format('create trigger %1$s_set_updated_at before update on %1$s for each row execute function set_updated_at()', t);
  end loop;
end $$;
