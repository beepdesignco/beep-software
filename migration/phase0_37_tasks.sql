-- Phase 0, step 37 — Asana-style Task / Work Management System foundation.
--
-- Five new tables to back the §13 (June 13 spec) task system:
--
--   tasks               — the core task record. Polymorphic links to
--                         project / proposal_item / invoice via separate
--                         nullable FKs (cleaner queries + RLS than a
--                         polymorphic link table). parent_task_id
--                         self-reference for subtasks. custom_fields jsonb
--                         + tags[] from day one so adding the UI later
--                         doesn't require migrating data.
--   task_comments       — flat (non-threaded). mentions uuid[] + attachments
--                         jsonb inline for @mentions and per-comment files.
--   task_activity       — audit log + notification source. One row per
--                         meaningful event (created/assigned/status_changed
--                         /commented/attached/etc.). studio_id denormalized
--                         for RLS performance.
--   task_field_defs     — schema for custom fields (text/number/date/
--                         select/multi_select/checkbox). UI lands Phase 2;
--                         column exists now so live data doesn't need
--                         backfill.
--   task_dependencies   — blocks / blocked_by. UI lands Phase 2 but schema
--                         is here so dependencies can be back-filled or
--                         migrated from CSV without changing the model.
--
-- All tables scope by studio_id via RLS using the existing
-- studio_members → user_id pattern.
--
-- Idempotent + defensive: uses CREATE TABLE IF NOT EXISTS plus
-- ALTER TABLE ... ADD COLUMN IF NOT EXISTS for each column so the migration
-- safely upgrades a partial pre-existing schema (e.g. a tasks table left
-- over from earlier development).

begin;

-- ── tasks ─────────────────────────────────────────────────────────────────

create table if not exists tasks (id uuid primary key default gen_random_uuid());

alter table tasks add column if not exists studio_id          uuid;
alter table tasks add column if not exists parent_task_id     uuid;
alter table tasks add column if not exists title              text;
alter table tasks add column if not exists description        text;
alter table tasks add column if not exists status             text not null default 'todo';
alter table tasks add column if not exists assignee_user_id   uuid;
alter table tasks add column if not exists due_date           date;
alter table tasks add column if not exists priority           text;
alter table tasks add column if not exists project_id         uuid;
alter table tasks add column if not exists proposal_item_id   uuid;
alter table tasks add column if not exists invoice_id         uuid;
alter table tasks add column if not exists custom_fields      jsonb not null default '{}'::jsonb;
alter table tasks add column if not exists tags               text[] not null default '{}';
alter table tasks add column if not exists attachments        jsonb not null default '[]'::jsonb;
alter table tasks add column if not exists sort_order         integer not null default 0;
alter table tasks add column if not exists completed_at       timestamptz;
alter table tasks add column if not exists created_at         timestamptz not null default now();
alter table tasks add column if not exists updated_at         timestamptz not null default now();
alter table tasks add column if not exists created_by_user_id uuid;
alter table tasks add column if not exists deleted_at         timestamptz;

-- Backfill foreign keys if not already set. Wrapped in DO so re-running
-- doesn't trip "constraint already exists" errors.
do $$
begin
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'tasks_studio_id_fkey') then
    alter table tasks add constraint tasks_studio_id_fkey foreign key (studio_id) references studios(id) on delete cascade;
  end if;
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'tasks_parent_task_id_fkey') then
    alter table tasks add constraint tasks_parent_task_id_fkey foreign key (parent_task_id) references tasks(id) on delete set null;
  end if;
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'tasks_assignee_user_id_fkey') then
    alter table tasks add constraint tasks_assignee_user_id_fkey foreign key (assignee_user_id) references auth.users(id) on delete set null;
  end if;
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'tasks_project_id_fkey') then
    alter table tasks add constraint tasks_project_id_fkey foreign key (project_id) references projects(id) on delete set null;
  end if;
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'tasks_proposal_item_id_fkey') then
    alter table tasks add constraint tasks_proposal_item_id_fkey foreign key (proposal_item_id) references proposal_items(id) on delete set null;
  end if;
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'tasks_invoice_id_fkey') then
    alter table tasks add constraint tasks_invoice_id_fkey foreign key (invoice_id) references invoices(id) on delete set null;
  end if;
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'tasks_created_by_user_id_fkey') then
    alter table tasks add constraint tasks_created_by_user_id_fkey foreign key (created_by_user_id) references auth.users(id) on delete set null;
  end if;
end$$;

create index if not exists tasks_studio_status_idx     on tasks (studio_id, status) where deleted_at is null;
create index if not exists tasks_project_idx           on tasks (project_id) where project_id is not null;
create index if not exists tasks_proposal_item_idx     on tasks (proposal_item_id) where proposal_item_id is not null;
create index if not exists tasks_invoice_idx           on tasks (invoice_id) where invoice_id is not null;
create index if not exists tasks_parent_idx            on tasks (parent_task_id) where parent_task_id is not null;
create index if not exists tasks_assignee_idx          on tasks (assignee_user_id) where deleted_at is null;
create index if not exists tasks_due_date_idx          on tasks (studio_id, due_date) where deleted_at is null and due_date is not null;
create index if not exists tasks_studio_sort_idx       on tasks (studio_id, sort_order) where deleted_at is null;

-- ── task_comments ─────────────────────────────────────────────────────────

create table if not exists task_comments (id uuid primary key default gen_random_uuid());

alter table task_comments add column if not exists task_id        uuid;
alter table task_comments add column if not exists author_user_id uuid;
alter table task_comments add column if not exists body           text;
alter table task_comments add column if not exists mentions       uuid[] not null default '{}';
alter table task_comments add column if not exists attachments    jsonb not null default '[]'::jsonb;
alter table task_comments add column if not exists created_at     timestamptz not null default now();
alter table task_comments add column if not exists edited_at      timestamptz;
alter table task_comments add column if not exists deleted_at     timestamptz;

do $$
begin
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'task_comments_task_id_fkey') then
    alter table task_comments add constraint task_comments_task_id_fkey foreign key (task_id) references tasks(id) on delete cascade;
  end if;
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'task_comments_author_user_id_fkey') then
    alter table task_comments add constraint task_comments_author_user_id_fkey foreign key (author_user_id) references auth.users(id) on delete set null;
  end if;
end$$;

create index if not exists task_comments_task_idx on task_comments (task_id, created_at);

-- ── task_activity ─────────────────────────────────────────────────────────

create table if not exists task_activity (id uuid primary key default gen_random_uuid());

alter table task_activity add column if not exists task_id       uuid;
alter table task_activity add column if not exists studio_id     uuid;
alter table task_activity add column if not exists actor_user_id uuid;
alter table task_activity add column if not exists kind          text;
alter table task_activity add column if not exists payload       jsonb not null default '{}'::jsonb;
alter table task_activity add column if not exists created_at    timestamptz not null default now();

do $$
begin
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'task_activity_task_id_fkey') then
    alter table task_activity add constraint task_activity_task_id_fkey foreign key (task_id) references tasks(id) on delete cascade;
  end if;
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'task_activity_studio_id_fkey') then
    alter table task_activity add constraint task_activity_studio_id_fkey foreign key (studio_id) references studios(id) on delete cascade;
  end if;
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'task_activity_actor_user_id_fkey') then
    alter table task_activity add constraint task_activity_actor_user_id_fkey foreign key (actor_user_id) references auth.users(id) on delete set null;
  end if;
end$$;

create index if not exists task_activity_task_idx   on task_activity (task_id, created_at desc);
create index if not exists task_activity_studio_idx on task_activity (studio_id, created_at desc);

-- ── task_field_defs ───────────────────────────────────────────────────────

create table if not exists task_field_defs (id uuid primary key default gen_random_uuid());

alter table task_field_defs add column if not exists studio_id     uuid;
alter table task_field_defs add column if not exists name          text;
alter table task_field_defs add column if not exists field_type    text;
alter table task_field_defs add column if not exists options       jsonb not null default '{}'::jsonb;
alter table task_field_defs add column if not exists default_value text;
alter table task_field_defs add column if not exists sort_order    integer not null default 0;
alter table task_field_defs add column if not exists created_at    timestamptz not null default now();
alter table task_field_defs add column if not exists deleted_at    timestamptz;

do $$
begin
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'task_field_defs_studio_id_fkey') then
    alter table task_field_defs add constraint task_field_defs_studio_id_fkey foreign key (studio_id) references studios(id) on delete cascade;
  end if;
end$$;

create index if not exists task_field_defs_studio_idx on task_field_defs (studio_id, sort_order) where deleted_at is null;

-- ── task_dependencies ─────────────────────────────────────────────────────

create table if not exists task_dependencies (id uuid primary key default gen_random_uuid());

alter table task_dependencies add column if not exists task_id            uuid;
alter table task_dependencies add column if not exists depends_on_task_id uuid;
alter table task_dependencies add column if not exists kind               text not null default 'blocks';
alter table task_dependencies add column if not exists created_at         timestamptz not null default now();

do $$
begin
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'task_dependencies_task_id_fkey') then
    alter table task_dependencies add constraint task_dependencies_task_id_fkey foreign key (task_id) references tasks(id) on delete cascade;
  end if;
  if not exists (select 1 from information_schema.referential_constraints where constraint_name = 'task_dependencies_depends_on_task_id_fkey') then
    alter table task_dependencies add constraint task_dependencies_depends_on_task_id_fkey foreign key (depends_on_task_id) references tasks(id) on delete cascade;
  end if;
  if not exists (select 1 from information_schema.table_constraints where constraint_name = 'task_dependencies_task_id_depends_on_task_id_kind_key') then
    alter table task_dependencies add constraint task_dependencies_task_id_depends_on_task_id_kind_key unique (task_id, depends_on_task_id, kind);
  end if;
end$$;

create index if not exists task_dependencies_task_idx       on task_dependencies (task_id);
create index if not exists task_dependencies_depends_on_idx on task_dependencies (depends_on_task_id);

-- ── RLS ───────────────────────────────────────────────────────────────────

alter table tasks            enable row level security;
alter table task_comments    enable row level security;
alter table task_activity    enable row level security;
alter table task_field_defs  enable row level security;
alter table task_dependencies enable row level security;

drop policy if exists tasks_member_all on tasks;
create policy tasks_member_all on tasks
  for all
  using  (studio_id in (select studio_id from studio_members where user_id = auth.uid()))
  with check (studio_id in (select studio_id from studio_members where user_id = auth.uid()));

drop policy if exists task_comments_member_all on task_comments;
create policy task_comments_member_all on task_comments
  for all
  using  (task_id in (select id from tasks where studio_id in (select studio_id from studio_members where user_id = auth.uid())))
  with check (task_id in (select id from tasks where studio_id in (select studio_id from studio_members where user_id = auth.uid())));

drop policy if exists task_activity_member_all on task_activity;
create policy task_activity_member_all on task_activity
  for all
  using  (studio_id in (select studio_id from studio_members where user_id = auth.uid()))
  with check (studio_id in (select studio_id from studio_members where user_id = auth.uid()));

drop policy if exists task_field_defs_member_all on task_field_defs;
create policy task_field_defs_member_all on task_field_defs
  for all
  using  (studio_id in (select studio_id from studio_members where user_id = auth.uid()))
  with check (studio_id in (select studio_id from studio_members where user_id = auth.uid()));

drop policy if exists task_dependencies_member_all on task_dependencies;
create policy task_dependencies_member_all on task_dependencies
  for all
  using  (task_id in (select id from tasks where studio_id in (select studio_id from studio_members where user_id = auth.uid())))
  with check (task_id in (select id from tasks where studio_id in (select studio_id from studio_members where user_id = auth.uid())));

commit;

-- Verify all 5 tables exist with the proposal_item_id column on tasks.
select 'tasks.proposal_item_id' as check, count(*) as exists
  from information_schema.columns
  where table_name = 'tasks' and column_name = 'proposal_item_id';

select table_name from information_schema.tables
  where table_name in ('tasks','task_comments','task_activity','task_field_defs','task_dependencies')
  order by table_name;
