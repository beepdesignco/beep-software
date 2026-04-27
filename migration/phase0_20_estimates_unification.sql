-- Phase 0, step 20 — unify proposal versioning into the existing
-- estimates system.
--
-- Phase0_19 added proposal_versions as a separate table; turns out the
-- existing estimates flow already snapshots the proposal state. So we
-- collapse the two:
--   1. Drop proposal_versions (created in 0_19, never used in earnest).
--   2. Wire the existing `estimates` table for studio scoping + sync
--      (it had a schema but nothing in the app actually persisted to it).
--   3. Add status (draft|proposed) + proposed_at + immutability trigger
--      so an estimate can be locked as "proposed to client."
--
-- Idempotent.

begin;

-- 1. Drop the unused proposal_versions table from phase0_19.
drop table if exists proposal_versions cascade;
drop function if exists proposal_versions_lock_proposed() cascade;

-- 2. Extend `estimates` with the columns we need for studio scoping +
--    cross-device persistence + lock workflow.
alter table estimates
  add column if not exists studio_id            uuid references studios(id) on delete cascade,
  add column if not exists status               text not null default 'draft',
  add column if not exists proposed_at          timestamptz,
  add column if not exists updated_by_user_id   uuid references auth.users(id);

-- Backfill studio_id from the parent project, then enforce NOT NULL.
update estimates e
   set studio_id = p.studio_id
  from projects p
 where e.project_id = p.id
   and e.studio_id is null;

alter table estimates alter column studio_id set not null;

-- Status check.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'estimates_status_chk'
  ) then
    alter table estimates
      add constraint estimates_status_chk check (status in ('draft','proposed'));
  end if;
end $$;

create index if not exists idx_estimates_studio_project
  on estimates(studio_id, project_id) where deleted_at is null;

-- 3. RLS — table existed but had no policies (because nothing wrote to
--    it). Enable RLS and add the standard studio-member-can-do-everything
--    policy used by every other studio-scoped table.
alter table estimates enable row level security;

drop policy if exists estimates_all on estimates;
create policy estimates_all on estimates for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

-- updated_at trigger (safe to add — no-op if estimates already had one).
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'estimates_set_updated_at') then
    create trigger estimates_set_updated_at before update on estimates
      for each row execute function set_updated_at();
  end if;
end $$;

-- 4. Immutability trigger: once status='proposed', the only field allowed
--    to change is deleted_at (so soft-delete still works for cleanup).
create or replace function estimates_lock_proposed()
returns trigger as $$
begin
  if old.status = 'proposed' then
    if new.snapshot is distinct from old.snapshot
       or new.custom_lines is distinct from old.custom_lines
       or new.name is distinct from old.name
       or new.freight is distinct from old.freight
       or new.freight_taxable is distinct from old.freight_taxable
       or new.hours is distinct from old.hours
       or new.hourly_rate is distinct from old.hourly_rate
       or new.receiving is distinct from old.receiving
       or new.storage is distinct from old.storage
       or new.tariffs_pct is distinct from old.tariffs_pct
       or new.status is distinct from old.status
       or new.proposed_at is distinct from old.proposed_at
       or new.project_id is distinct from old.project_id
       or new.studio_id is distinct from old.studio_id
    then
      raise exception 'estimates row % is proposed and immutable (only deleted_at may change)', old.id;
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'estimates_lock_trigger') then
    create trigger estimates_lock_trigger before update on estimates
      for each row execute function estimates_lock_proposed();
  end if;
end $$;

commit;

select column_name, data_type, is_nullable from information_schema.columns
  where table_name = 'estimates' order by ordinal_position;
select policyname from pg_policies where tablename = 'estimates';
