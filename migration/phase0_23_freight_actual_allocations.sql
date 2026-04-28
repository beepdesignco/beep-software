-- Phase 0, step 23 — freight_actual_allocations.
--
-- One freight bill (e.g. moving company invoice covering 6 items) can
-- now be split across multiple proposal items. Each row here is a slice
-- of a freight_actual targeting a specific item with its $ amount.
--
-- PM per-item rollup, the freight reconciliation calc, and the freight
-- tracker grid all read allocations when present, falling back to the
-- legacy freight_actuals.proposal_item_id single-FK when no allocations
-- exist.
--
-- proposal_item_id on freight_actuals is relaxed to nullable: split
-- bills don't have a single primary item.
--
-- Idempotent.

begin;

alter table freight_actuals
  alter column proposal_item_id drop not null;

create table if not exists freight_actual_allocations (
  id                    uuid primary key default gen_random_uuid(),
  studio_id             uuid not null references studios(id) on delete cascade,
  freight_actual_id     uuid not null references freight_actuals(id) on delete cascade,
  proposal_item_id      uuid references proposal_items(id) on delete set null,
  amount                numeric(12,2) not null,
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,
  created_by_user_id    uuid references auth.users(id),
  updated_by_user_id    uuid references auth.users(id)
);

create index if not exists idx_freight_actual_allocations_actual
  on freight_actual_allocations(freight_actual_id) where deleted_at is null;

create index if not exists idx_freight_actual_allocations_item
  on freight_actual_allocations(proposal_item_id) where deleted_at is null;

alter table freight_actual_allocations enable row level security;

drop policy if exists freight_actual_allocations_all on freight_actual_allocations;
create policy freight_actual_allocations_all on freight_actual_allocations for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'freight_actual_allocations_set_updated_at') then
    create trigger freight_actual_allocations_set_updated_at before update on freight_actual_allocations
      for each row execute function set_updated_at();
  end if;
end $$;

commit;

select column_name, data_type, is_nullable from information_schema.columns
  where table_name = 'freight_actual_allocations' order by ordinal_position;
