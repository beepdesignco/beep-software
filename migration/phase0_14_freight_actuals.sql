-- Phase 0, step 14 — U-Freight Phase 4 Part 1: freight_actuals.
--
-- Vendor freight bills logged against specific items for retainer
-- reconciliation. Distinct from `expenses` (which is the general cost +
-- P&L log). A freight_actual can OPTIONALLY also create a linked
-- nonbillable expense via the linked_expense_id column, for studios who
-- want freight costs to land in P&L. Phase 4 Part 2 reads this table to
-- compute charged-vs-actual variances per item.
--
-- Idempotent.

begin;

create table if not exists freight_actuals (
  id                    uuid primary key default gen_random_uuid(),
  studio_id             uuid not null references studios(id) on delete cascade,
  project_id            uuid not null references projects(id) on delete cascade,
  proposal_item_id      uuid not null references proposal_items(id) on delete cascade,
  proposal_component_id uuid references proposal_components(id) on delete set null,
  freight_category_id   uuid references freight_categories(id) on delete set null,
  amount                numeric(12,2) not null,
  date                  date not null default current_date,
  vendor_id             uuid references vendors(id) on delete set null,
  invoice_reference     text,
  notes                 text,
  linked_expense_id     uuid references expenses(id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,
  created_by_user_id    uuid references auth.users(id),
  updated_by_user_id    uuid references auth.users(id),
  constraint freight_actuals_amount_chk check (amount >= 0)
);

create index if not exists idx_freight_actuals_project
  on freight_actuals(studio_id, project_id)
  where deleted_at is null;

create index if not exists idx_freight_actuals_item
  on freight_actuals(proposal_item_id)
  where deleted_at is null;

create index if not exists idx_freight_actuals_expense
  on freight_actuals(linked_expense_id)
  where linked_expense_id is not null and deleted_at is null;

alter table freight_actuals enable row level security;

drop policy if exists freight_actuals_all on freight_actuals;
create policy freight_actuals_all on freight_actuals for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'freight_actuals_set_updated_at') then
    create trigger freight_actuals_set_updated_at before update on freight_actuals
      for each row execute function set_updated_at();
  end if;
end $$;

commit;

-- Verification
select column_name, data_type, is_nullable
  from information_schema.columns
  where table_name = 'freight_actuals'
  order by ordinal_position;

select indexname from pg_indexes where tablename = 'freight_actuals' order by indexname;

select policyname from pg_policies where tablename = 'freight_actuals';
