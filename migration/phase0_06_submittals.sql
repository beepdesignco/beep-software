-- Phase 0, step 6 — Submittals (simplified sign-off workflow).
--
-- Per the Phase 0 spec: no formal state machine. A submittal is:
--   • A document being sent for sign-off (either a row in `documents` or a
--     file attached directly to the submittal)
--   • A list of required signers (drawn from `contacts`)
--   • Per signer: signed_off flag + auto-captured signed_off_at timestamp +
--     optional signer_notes
--   • Optional submittal-level notes
--
-- Derived status is computed at query time:
--   • complete  — every required signer has signed_off = true
--   • pending   — otherwise
--
-- The UI surface lives under the Documents tab (Submittals subsection).
-- The spec's tab reorganization (Project Uploads / Generated Documents /
-- Submittals) is purely client-side — no schema change needed for that.
-- Project Uploads continues to use `projects.files`, Generated Documents
-- continues to use `documents` + `document_versions`.
--
-- Events: `submittal.sent`, `submittal.signed`, `submittal.completed`,
-- `submittal.signer_added`, etc. are emitted into activity_entries by
-- the app layer (not DB triggers) so they appear in the chronological chart
-- and weekly digest.
--
-- Idempotent: safe to re-run.

begin;

-- ════════════════════════════════════════════════════════════════
-- SUBMITTALS
-- ════════════════════════════════════════════════════════════════

create table if not exists submittals (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  project_id          uuid not null references projects(id) on delete cascade,
  -- Optional link to a generated document (documents table). When null, the
  -- submittal stands on its own files jsonb.
  document_id         uuid references documents(id) on delete set null,
  title               text not null,
  notes               text,
  -- Direct attachments (when not linked to a generated document, or in
  -- addition to one). Same shape as proposal_items.files:
  --   [{id, name, storage_path, size, type}, ...]
  files               jsonb not null default '[]'::jsonb,
  -- Lifecycle timestamps (null until reached)
  sent_at             timestamptz,           -- set when the submittal is dispatched to signers
  completed_at        timestamptz,           -- set by the app when every signer signs off
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  created_by_user_id  uuid references auth.users(id),
  updated_by_user_id  uuid references auth.users(id)
);

create index if not exists idx_submittals_studio
  on submittals(studio_id)
  where deleted_at is null;

create index if not exists idx_submittals_project
  on submittals(project_id)
  where deleted_at is null;

create index if not exists idx_submittals_document
  on submittals(document_id)
  where document_id is not null and deleted_at is null;

create index if not exists idx_submittals_pending
  on submittals(studio_id, created_at desc)
  where deleted_at is null and completed_at is null;

alter table submittals enable row level security;

drop policy if exists submittals_all on submittals;
create policy submittals_all on submittals for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'submittals_set_updated_at') then
    create trigger submittals_set_updated_at before update on submittals
      for each row execute function set_updated_at();
  end if;
end $$;

-- ════════════════════════════════════════════════════════════════
-- SUBMITTAL_SIGNERS
-- ════════════════════════════════════════════════════════════════

create table if not exists submittal_signers (
  id                      uuid primary key default gen_random_uuid(),
  submittal_id            uuid not null references submittals(id) on delete cascade,
  contact_id              uuid not null references contacts(id) on delete cascade,
  signed_off              boolean not null default false,
  signed_off_at           timestamptz,
  signed_off_by_user_id   uuid references auth.users(id),        -- which studio member marked it
  signer_notes            text,
  sort_order              integer not null default 0,
  created_at              timestamptz not null default now(),
  unique (submittal_id, contact_id)
);

create index if not exists idx_submittal_signers_submittal
  on submittal_signers(submittal_id);

create index if not exists idx_submittal_signers_contact
  on submittal_signers(contact_id);

-- Fast query for "any submittal waiting on at least one signer"
create index if not exists idx_submittal_signers_pending
  on submittal_signers(submittal_id)
  where signed_off = false;

alter table submittal_signers enable row level security;

-- Gate via the submittal's studio.
drop policy if exists submittal_signers_all on submittal_signers;
create policy submittal_signers_all on submittal_signers for all
  using (
    exists (select 1 from submittals s where s.id = submittal_id and is_studio_member(s.studio_id))
  )
  with check (
    exists (select 1 from submittals s where s.id = submittal_id and is_studio_member(s.studio_id))
  );

-- Auto-capture signed_off_at when signed_off flips true, clear it when flipped false.
create or replace function submittal_signer_stamp_signoff()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.signed_off and new.signed_off_at is null then
      new.signed_off_at := now();
    end if;
  elsif tg_op = 'UPDATE' then
    if new.signed_off and not old.signed_off then
      if new.signed_off_at is null then new.signed_off_at := now(); end if;
    elsif not new.signed_off and old.signed_off then
      new.signed_off_at := null;
    end if;
  end if;
  return new;
end $$;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'submittal_signers_stamp_signoff') then
    create trigger submittal_signers_stamp_signoff
      before insert or update on submittal_signers
      for each row execute function submittal_signer_stamp_signoff();
  end if;
end $$;

-- ════════════════════════════════════════════════════════════════
-- HELPER FUNCTION for child-table RLS (future-proofing)
-- ════════════════════════════════════════════════════════════════

create or replace function studio_of_submittal(target_submittal uuid)
returns uuid language sql security definer stable
set search_path = public, auth as $$
  select studio_id from public.submittals where id = target_submittal;
$$;

grant execute on function studio_of_submittal(uuid) to authenticated, anon;

commit;

-- ════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- ════════════════════════════════════════════════════════════════

-- 1. Tables exist (expect 2 rows).
select table_name from information_schema.tables
  where table_schema = 'public'
    and table_name in ('submittals', 'submittal_signers')
  order by table_name;

-- 2. RLS policies (expect 2 rows: submittals_all, submittal_signers_all).
select tablename, policyname, cmd
  from pg_policies
  where tablename in ('submittals', 'submittal_signers')
  order by tablename, policyname;

-- 3. Triggers (expect 3: submittals_set_updated_at, submittal_signers_stamp_signoff, plus whatever pg shows for signers).
select trigger_name, event_manipulation, event_object_table
  from information_schema.triggers
  where event_object_table in ('submittals', 'submittal_signers')
  order by event_object_table, trigger_name;

-- 4. studio_of_submittal helper exists (expect 1 row).
select proname from pg_proc where proname = 'studio_of_submittal';

-- 5. Indexes (expect 6).
select indexname, tablename from pg_indexes
  where indexname in (
    'idx_submittals_studio',
    'idx_submittals_project',
    'idx_submittals_document',
    'idx_submittals_pending',
    'idx_submittal_signers_submittal',
    'idx_submittal_signers_contact',
    'idx_submittal_signers_pending'
  )
  order by indexname;
