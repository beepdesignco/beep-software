-- Phase 0, step 16 — U-Freight Phase 5 Part 2: freight_settlements.
--
-- Records each time a freight credit is applied, an overage is billed,
-- or a deferred actual is billed on an invoice. Source of truth for
-- "what's been settled" so the project net doesn't double-count.
--
-- Settlements with linked invoices in 'cancelled' status are treated as
-- void at calc time (filter in the app, not the schema) — the row stays
-- so we have an audit trail.
--
-- Idempotent.

begin;

create table if not exists freight_settlements (
  id                   uuid primary key default gen_random_uuid(),
  studio_id            uuid not null references studios(id) on delete cascade,
  project_id           uuid not null references projects(id) on delete cascade,
  invoice_id           uuid not null references invoices(id) on delete cascade,
  type                 text not null,
  amount               numeric(12,2) not null,
  notes                text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz,
  created_by_user_id   uuid references auth.users(id),
  updated_by_user_id   uuid references auth.users(id),
  constraint freight_settlements_type_chk check (type in ('credit_applied', 'overage_billed', 'deferred_billed'))
);

create index if not exists idx_freight_settlements_project
  on freight_settlements(studio_id, project_id)
  where deleted_at is null;

create index if not exists idx_freight_settlements_invoice
  on freight_settlements(invoice_id)
  where deleted_at is null;

alter table freight_settlements enable row level security;

drop policy if exists freight_settlements_all on freight_settlements;
create policy freight_settlements_all on freight_settlements for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'freight_settlements_set_updated_at') then
    create trigger freight_settlements_set_updated_at before update on freight_settlements
      for each row execute function set_updated_at();
  end if;
end $$;

commit;

select column_name, data_type, is_nullable from information_schema.columns
  where table_name = 'freight_settlements' order by ordinal_position;
select indexname from pg_indexes where tablename = 'freight_settlements' order by indexname;
