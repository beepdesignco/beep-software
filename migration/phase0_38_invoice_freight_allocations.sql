-- Phase 0, step 38 — §1 freight overhaul Phase A: foundation tables.
--
-- Two additions in service of the unified freight allocation model.
--
-- (1) invoice_freight_allocations — per-item share of an invoice's freight
--     $. Mirrors the existing freight_actual_allocations table (phase0_23),
--     same shape, same fold-onto-parent pattern in JS. Lets us answer
--     "how much freight did this item collect?" without re-deriving from
--     invoice line items every read.
--
--     allocation_source captures HOW the row was generated:
--       'auto_proportional' — invoice was sent with mode A (known $) or
--                             mode B (retainer %), and the freight $ was
--                             split across the invoice's freight-pool
--                             items proportional to subtotal.
--       'manual'            — user hand-allocated shares in the UI.
--       'deferred_billed'   — a deferred freight charge (mode C) was
--                             billed and the user picked which items it
--                             covers.
--
-- (2) proposal_items.freight_approved_snapshot (JSONB) — frozen at the
--     moment an estimate version is approved. Holds the freight % and $
--     as agreed by the client. PM display reads this for the
--     estimated/collected/actual triplet. Never overwritten after
--     approval; the item is free to be re-estimated, but the snapshot
--     stays anchored to what the client actually saw + agreed to.
--
--     Shape:
--       {
--         "approvedAt": "2026-06-18T12:34:56Z",
--         "estimateVersionId": "<estimates.id>",
--         "percentApplied": 8.5,        -- null if billed as exact $
--         "dollarValue": 1234.56,       -- per-item $ snapshot
--         "billingMode": "retainer" | "known"
--       }
--
-- Idempotent.

begin;

-- (1) invoice_freight_allocations
create table if not exists invoice_freight_allocations (
  id                    uuid primary key default gen_random_uuid(),
  studio_id             uuid not null references studios(id) on delete cascade,
  invoice_id            uuid not null references invoices(id) on delete cascade,
  proposal_item_id      uuid references proposal_items(id) on delete set null,
  amount                numeric(12,2) not null,
  share_pct             numeric(8,4),
  allocation_source     text not null default 'auto_proportional',
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz,
  created_by_user_id    uuid references auth.users(id),
  updated_by_user_id    uuid references auth.users(id),
  constraint invoice_freight_allocations_amount_chk check (amount >= 0),
  constraint invoice_freight_allocations_source_chk
    check (allocation_source in ('auto_proportional', 'manual', 'deferred_billed'))
);

create index if not exists idx_invoice_freight_allocations_invoice
  on invoice_freight_allocations(studio_id, invoice_id) where deleted_at is null;

create index if not exists idx_invoice_freight_allocations_item
  on invoice_freight_allocations(proposal_item_id) where deleted_at is null;

alter table invoice_freight_allocations enable row level security;

drop policy if exists invoice_freight_allocations_all on invoice_freight_allocations;
create policy invoice_freight_allocations_all on invoice_freight_allocations for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'invoice_freight_allocations_set_updated_at') then
    create trigger invoice_freight_allocations_set_updated_at before update on invoice_freight_allocations
      for each row execute function set_updated_at();
  end if;
end $$;

-- (2) proposal_items.freight_approved_snapshot
alter table proposal_items
  add column if not exists freight_approved_snapshot jsonb;

commit;

-- Verify
select column_name, data_type, is_nullable from information_schema.columns
  where table_name = 'invoice_freight_allocations' order by ordinal_position;

select indexname from pg_indexes where tablename = 'invoice_freight_allocations' order by indexname;

select policyname from pg_policies where tablename = 'invoice_freight_allocations';

select column_name, data_type from information_schema.columns
  where table_name = 'proposal_items' and column_name = 'freight_approved_snapshot';
