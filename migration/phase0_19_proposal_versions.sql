-- Phase 0, step 19 — proposal_versions.
--
-- Snapshot history of a project's proposal. Working copy stays the
-- source of truth for PM / invoicing / expenses; this table is purely
-- a client-facing audit trail of what was proposed at each point.
--
-- Lifecycle:
--   draft     → editable; can tweak estimates / items pre-send
--   proposed  → locked; immutable. To revise, snapshot a new version.
--
-- A trigger blocks updates (other than deleted_at) to rows in 'proposed'
-- status — defense in depth so an app bug can't silently corrupt the
-- historical record.
--
-- Idempotent.

begin;

create table if not exists proposal_versions (
  id                   uuid primary key default gen_random_uuid(),
  studio_id            uuid not null references studios(id) on delete cascade,
  project_id           uuid not null references projects(id) on delete cascade,
  version_number       int not null,
  status               text not null default 'draft',
  snapshot_json        jsonb not null,
  proposed_at          timestamptz,
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz,
  created_by_user_id   uuid references auth.users(id),
  updated_by_user_id   uuid references auth.users(id),
  constraint proposal_versions_status_chk check (status in ('draft', 'proposed'))
);

create unique index if not exists uq_proposal_versions_project_version
  on proposal_versions(project_id, version_number)
  where deleted_at is null;

create index if not exists idx_proposal_versions_project
  on proposal_versions(studio_id, project_id)
  where deleted_at is null;

alter table proposal_versions enable row level security;

drop policy if exists proposal_versions_all on proposal_versions;
create policy proposal_versions_all on proposal_versions for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'proposal_versions_set_updated_at') then
    create trigger proposal_versions_set_updated_at before update on proposal_versions
      for each row execute function set_updated_at();
  end if;
end $$;

-- Block edits to proposed versions (deleted_at is the only field allowed
-- to change, so soft-delete still works for cleanup).
create or replace function proposal_versions_lock_proposed()
returns trigger as $$
begin
  if old.status = 'proposed' then
    if new.snapshot_json is distinct from old.snapshot_json
       or new.version_number is distinct from old.version_number
       or new.status is distinct from old.status
       or new.proposed_at is distinct from old.proposed_at
       or new.notes is distinct from old.notes
       or new.project_id is distinct from old.project_id
       or new.studio_id is distinct from old.studio_id
    then
      raise exception 'proposal_versions row % is proposed and immutable (only deleted_at may change)', old.id;
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'proposal_versions_lock_trigger') then
    create trigger proposal_versions_lock_trigger before update on proposal_versions
      for each row execute function proposal_versions_lock_proposed();
  end if;
end $$;

commit;

select column_name, data_type, is_nullable from information_schema.columns
  where table_name = 'proposal_versions' order by ordinal_position;
select indexname from pg_indexes where tablename = 'proposal_versions' order by indexname;
