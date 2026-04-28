-- Phase 0, step 22 — add 'approved' as a third estimate version status.
--
-- Lifecycle: draft → proposed (locked) OR draft → approved (locked).
-- Drafts can flip directly to either; both terminal states are immutable.
--
-- Lock trigger updated to block updates on rows in EITHER status.
--
-- Idempotent.

begin;

-- Replace the status check constraint to accept 'approved'.
alter table estimates drop constraint if exists estimates_status_chk;
alter table estimates
  add constraint estimates_status_chk check (status in ('draft','proposed','approved'));

-- Replace the lock trigger function to treat both proposed and approved as
-- terminal/immutable. Body is unchanged except for the status guard.
create or replace function estimates_lock_proposed()
returns trigger as $$
begin
  if old.status in ('proposed', 'approved') then
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
      raise exception 'estimates row % is %s and immutable (only deleted_at may change)', old.id, old.status;
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

commit;

select column_name, data_type from information_schema.columns
  where table_name = 'estimates' and column_name in ('status','proposed_at');
select conname, pg_get_constraintdef(oid) from pg_constraint
  where conname = 'estimates_status_chk';
