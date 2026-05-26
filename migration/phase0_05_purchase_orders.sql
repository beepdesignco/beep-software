-- Phase 0, step 5 — Purchase Orders (minimum viable).
--
-- State machine (v-coded; labels/colors/order customizable via studios.settings
-- like proposal item statuses):
--   v_draft → v_sent → v_acknowledged → v_shipped → v_received → v_closed
--   v_cancelled is a side exit from any state; terminal.
--   Acknowledged and Shipped are OPTIONAL intermediates.
--   Enforcement of valid transitions lives in app layer, not DB, to match
--   the existing invoice-status approach.
--
-- Numbering: per-studio integer, starting at 101 (app-layer assigns via
-- max(po_number)+1 within the studio; DB guarantees uniqueness).
--
-- Sidemark: stored on each PO. Default template lives in
-- studios.settings.sidemark_template with tokens:
--   {client.lastName}, {client.firstName}, {project.code}, {project.name},
--   {vendor.name}, {space.name}, {po.number}
-- Template is resolved at PO creation; per-PO field is editable so manual
-- override wins.
--
-- Relationships:
--   • proposal_items.po_id nullable — one PO has many items, one item on
--     one PO at a time. When an item moves off a PO (or the PO is cancelled),
--     po_id clears and the item is eligible for another PO.
--   • expenses.po_id nullable — vendor invoice logged as expense can
--     optionally link back to its originating PO.
--
-- Idempotent: safe to re-run.

begin;

-- ════════════════════════════════════════════════════════════════
-- PURCHASE_ORDERS
-- ════════════════════════════════════════════════════════════════

create table if not exists purchase_orders (
  id                   uuid primary key default gen_random_uuid(),
  studio_id            uuid not null references studios(id) on delete cascade,
  project_id           uuid references projects(id) on delete set null,
  vendor_id            uuid references vendors(id) on delete set null,
  vendor_contact_id    uuid references vendor_contacts(id) on delete set null,
  po_number            integer not null,
  status               text not null default 'v_draft',
  sidemark             text,                                 -- resolved from template + user-editable
  ship_window_start    date,
  ship_window_end      date,
  ship_notes           text,
  notes                text,
  files                jsonb not null default '[]'::jsonb,   -- attachments (quotes, vendor acknowledgements, etc.)
  -- Per-state timestamps (null until reached; for history + reporting)
  sent_at              timestamptz,
  acknowledged_at      timestamptz,
  shipped_at           timestamptz,
  received_at          timestamptz,
  closed_at            timestamptz,
  cancelled_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz,
  created_by_user_id   uuid references auth.users(id),
  updated_by_user_id   uuid references auth.users(id)
);

-- Status check — same v-coded pattern as proposal item statuses.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'purchase_orders_status_check'
  ) then
    alter table purchase_orders
      add constraint purchase_orders_status_check
      check (status in ('v_draft','v_sent','v_acknowledged','v_shipped','v_received','v_closed','v_cancelled'));
  end if;
end $$;

-- Ensure ship_window_end is on/after ship_window_start when both set
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'purchase_orders_ship_window_valid'
  ) then
    alter table purchase_orders
      add constraint purchase_orders_ship_window_valid
      check (
        ship_window_start is null
        or ship_window_end is null
        or ship_window_end >= ship_window_start
      );
  end if;
end $$;

-- Per-studio uniqueness on PO number (live rows only; soft-deleted numbers
-- become available again — app-layer numbering skips deleted via max()).
create unique index if not exists uq_pos_studio_number
  on purchase_orders(studio_id, po_number)
  where deleted_at is null;

create index if not exists idx_pos_studio
  on purchase_orders(studio_id)
  where deleted_at is null;

create index if not exists idx_pos_project
  on purchase_orders(project_id)
  where project_id is not null and deleted_at is null;

create index if not exists idx_pos_vendor
  on purchase_orders(vendor_id)
  where vendor_id is not null and deleted_at is null;

create index if not exists idx_pos_status
  on purchase_orders(studio_id, status)
  where deleted_at is null;

alter table purchase_orders enable row level security;

-- Gate on view_financials to match invoice/expense pattern. POs carry vendor
-- cost info — members without financial permissions can't see them. If that
-- becomes a coordination problem we can loosen SELECT later.
drop policy if exists purchase_orders_select on purchase_orders;
drop policy if exists purchase_orders_modify on purchase_orders;

create policy purchase_orders_select on purchase_orders for select
  using (has_permission(studio_id, 'view_financials'));

create policy purchase_orders_modify on purchase_orders for all
  using (has_permission(studio_id, 'view_financials'))
  with check (has_permission(studio_id, 'view_financials'));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'purchase_orders_set_updated_at') then
    create trigger purchase_orders_set_updated_at before update on purchase_orders
      for each row execute function set_updated_at();
  end if;
end $$;

-- Studio-lookup helper for child tables that only know a po_id (mirrors
-- studio_of_invoice / studio_of_project / etc.).
create or replace function studio_of_po(target_po uuid)
returns uuid language sql security definer stable
set search_path = public, auth as $$
  select studio_id from public.purchase_orders where id = target_po;
$$;

grant execute on function studio_of_po(uuid) to authenticated, anon;

-- ════════════════════════════════════════════════════════════════
-- FK ON proposal_items.po_id
-- ════════════════════════════════════════════════════════════════

alter table proposal_items
  add column if not exists po_id uuid references purchase_orders(id) on delete set null;

create index if not exists idx_items_po
  on proposal_items(po_id)
  where po_id is not null and deleted_at is null;

-- ════════════════════════════════════════════════════════════════
-- FK ON expenses.po_id (optional link back from a vendor-invoice expense)
-- ════════════════════════════════════════════════════════════════

alter table expenses
  add column if not exists po_id uuid references purchase_orders(id) on delete set null;

create index if not exists idx_expenses_po
  on expenses(po_id)
  where po_id is not null and deleted_at is null;

commit;

-- ════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- ════════════════════════════════════════════════════════════════

-- 1. Table exists (expect 1 row).
select table_name from information_schema.tables
  where table_schema = 'public' and table_name = 'purchase_orders';

-- 2. Status check constraint is present (expect 1 row).
select conname, pg_get_constraintdef(oid) as definition
  from pg_constraint
  where conrelid = 'purchase_orders'::regclass
    and conname in ('purchase_orders_status_check', 'purchase_orders_ship_window_valid');

-- 3. FKs added to proposal_items + expenses (expect 2 rows).
select table_name, column_name, data_type, is_nullable
  from information_schema.columns
  where (table_name = 'proposal_items' and column_name = 'po_id')
     or (table_name = 'expenses'       and column_name = 'po_id')
  order by table_name;

-- 4. RLS policies on purchase_orders (expect 2 rows: select + modify).
select policyname, cmd from pg_policies
  where tablename = 'purchase_orders'
  order by policyname;

-- 5. studio_of_po helper function exists (expect 1 row).
select proname from pg_proc where proname = 'studio_of_po';

-- 6. All new indexes present (expect 7).
select indexname, tablename from pg_indexes
  where indexname in (
    'uq_pos_studio_number',
    'idx_pos_studio',
    'idx_pos_project',
    'idx_pos_vendor',
    'idx_pos_status',
    'idx_items_po',
    'idx_expenses_po'
  )
  order by indexname;
