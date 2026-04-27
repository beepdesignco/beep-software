-- Phase 0, step 21 — expense_allocations.
--
-- One expense can be split across multiple proposal items. Each row
-- here is one slice. PM actual-cost rollup and invoice line generation
-- both read allocations when present (and fall back to the legacy
-- expense.proposal_item_id single-FK when no allocations exist).
--
-- Per-allocation status (draft → invoiced → resolved) lets the fabric
-- scenario work: pillow's slice can be invoiced in Phase 1 while the
-- headboard's slice waits for Phase 2.
--
-- Idempotent.

begin;

create table if not exists expense_allocations (
  id                    uuid primary key default gen_random_uuid(),
  studio_id             uuid not null references studios(id) on delete cascade,
  expense_id            uuid not null references expenses(id) on delete cascade,
  proposal_item_id      uuid references proposal_items(id) on delete set null,
  amount                numeric(12,2) not null,
  notes                 text,
  status                text not null default 'draft',
  invoice_line_item_id  uuid references invoice_line_items(id) on delete set null,
  resolved_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,
  created_by_user_id    uuid references auth.users(id),
  updated_by_user_id    uuid references auth.users(id),
  constraint expense_allocations_status_chk check (status in ('draft','invoiced','resolved'))
);

create index if not exists idx_expense_allocations_expense
  on expense_allocations(expense_id) where deleted_at is null;

create index if not exists idx_expense_allocations_item
  on expense_allocations(proposal_item_id) where deleted_at is null;

create index if not exists idx_expense_allocations_invoice_line
  on expense_allocations(invoice_line_item_id) where deleted_at is null;

alter table expense_allocations enable row level security;

drop policy if exists expense_allocations_all on expense_allocations;
create policy expense_allocations_all on expense_allocations for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'expense_allocations_set_updated_at') then
    create trigger expense_allocations_set_updated_at before update on expense_allocations
      for each row execute function set_updated_at();
  end if;
end $$;

commit;

select column_name, data_type, is_nullable from information_schema.columns
  where table_name = 'expense_allocations' order by ordinal_position;
select indexname from pg_indexes where tablename = 'expense_allocations' order by indexname;
