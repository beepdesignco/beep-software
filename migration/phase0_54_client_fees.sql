-- Client fees: revenue-only charges (e.g. a $35 receiving fee) that book
-- NO cost. A freight category flagged is_fee redirects "Log Freight
-- Actual" to create a client_fees row instead of a freight_actual — fees
-- must not enter freight cost/reconciliation math (collected-with-no-cost
-- would read as a client credit there). Fees queue as "Unbilled Fees" in
-- the invoice builder and land as taxable revenue lines attributed to
-- their item.

begin;

alter table freight_categories
  add column if not exists is_fee boolean not null default false;

create table if not exists client_fees (
  id uuid primary key,
  studio_id uuid not null references studios(id) on delete cascade,
  project_id uuid not null references projects(id) on delete cascade,
  proposal_item_id uuid references proposal_items(id) on delete set null,
  proposal_component_id uuid references proposal_components(id) on delete set null,
  freight_category_id uuid references freight_categories(id) on delete set null,
  label text,
  amount numeric not null default 0,
  taxable boolean not null default true,
  date date,
  notes text,
  status text not null default 'unbilled' check (status in ('unbilled','billed')),
  invoice_line_item_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists client_fees_project_idx on client_fees(project_id) where deleted_at is null;

alter table client_fees enable row level security;

drop policy if exists client_fees_all on client_fees;
create policy client_fees_all on client_fees
  for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'client_fees_set_updated_at') then
    create trigger client_fees_set_updated_at before update on client_fees
      for each row execute function set_updated_at();
  end if;
end $$;

commit;

select tablename from pg_tables where tablename = 'client_fees';
