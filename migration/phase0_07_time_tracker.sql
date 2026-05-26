-- Phase 0, step 7 — Time tracker overhaul (schema).
--
-- Spec recap (app-layer behavior notes kept here for reviewer context):
--   • Second-level precision — already supported (duration_seconds int + timestamps).
--   • Hourly rate per studio member (used as default for new time entries).
--   • Per-entry rate snapshot so rate changes never mutate already-logged work.
--   • Time entries carry a status: 'unbilled' → 'billed'. Once 'billed', the
--     row is locked at the RLS layer (no update, no delete by normal users).
--   • Entries reference an invoice_line_item when billed. Multiple entries
--     may point to the same line item (collated client-facing line) while
--     the internal view preserves per-employee breakdown.
--   • Project-level time_taxable flag, modeled on the existing
--     projects.freight_taxable pattern.
--   • Void/refund flow: when an invoice is voided/cancelled, the app clears
--     status back to 'unbilled' and clears invoice_line_item_id + billed_at.
--     DB allows that path because the locking only applies while status='billed'.
--
-- App-layer items not needing schema: unbilled-time notification on invoice
-- creation, "Add unbilled time" modal, collation UI, HH:MM:SS formatting,
-- midnight-crossing single-entry behavior, reports/history filters.
--
-- Idempotent: safe to re-run.

begin;

-- ════════════════════════════════════════════════════════════════
-- studio_members.hourly_rate  (default rate per team member)
-- ════════════════════════════════════════════════════════════════

alter table studio_members
  add column if not exists hourly_rate numeric(10,2);

-- ════════════════════════════════════════════════════════════════
-- projects.time_taxable  (mirrors freight_taxable)
-- ════════════════════════════════════════════════════════════════

alter table projects
  add column if not exists time_taxable boolean not null default false;

-- ════════════════════════════════════════════════════════════════
-- time_entries — billed-status, per-entry rate, invoice link
-- ════════════════════════════════════════════════════════════════

alter table time_entries
  add column if not exists rate                 numeric(10,2),
  add column if not exists status               text not null default 'unbilled',
  add column if not exists invoice_line_item_id uuid references invoice_line_items(id) on delete set null,
  add column if not exists billed_at            timestamptz;

-- Allowed status values
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'time_entries_status_check'
  ) then
    alter table time_entries
      add constraint time_entries_status_check
      check (status in ('unbilled', 'billed'));
  end if;
end $$;

-- When status='billed', both invoice_line_item_id and billed_at must be set.
-- When status='unbilled', both must be null. Keeps the state consistent
-- regardless of which code path transitions the row.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'time_entries_billed_consistency'
  ) then
    alter table time_entries
      add constraint time_entries_billed_consistency
      check (
        (status = 'billed'   and invoice_line_item_id is not null and billed_at is not null)
        or
        (status = 'unbilled' and invoice_line_item_id is null     and billed_at is null)
      );
  end if;
end $$;

-- ════════════════════════════════════════════════════════════════
-- INDEXES — support "my unbilled time" + "unbilled time on this project"
-- + "all time billed on this invoice line"
-- ════════════════════════════════════════════════════════════════

create index if not exists idx_time_user_status
  on time_entries(user_id, status, started_at desc);

create index if not exists idx_time_project_status
  on time_entries(project_id, status)
  where project_id is not null;

create index if not exists idx_time_invoice_line_item
  on time_entries(invoice_line_item_id)
  where invoice_line_item_id is not null;

-- ════════════════════════════════════════════════════════════════
-- RLS — split the current combined policy so billed rows are immutable
-- ════════════════════════════════════════════════════════════════

drop policy if exists time_select on time_entries;
drop policy if exists time_modify on time_entries;
drop policy if exists time_insert on time_entries;
drop policy if exists time_update on time_entries;
drop policy if exists time_delete on time_entries;

-- SELECT — user sees own entries; owner sees everyone's.
create policy time_select on time_entries for select
  using (user_id = auth.uid() or is_studio_owner(studio_id));

-- INSERT — only your own entries, in a studio you're a member of.
create policy time_insert on time_entries for insert
  with check (user_id = auth.uid() and is_studio_member(studio_id));

-- UPDATE — only your own unbilled entries. Once billed, it's locked at the
-- RLS layer. Void/refund flow resets status→'unbilled' via security-definer
-- function (which bypasses RLS), so app can still reopen entries when an
-- invoice is voided.
create policy time_update on time_entries for update
  using (user_id = auth.uid() and is_studio_member(studio_id) and status = 'unbilled')
  with check (user_id = auth.uid() and is_studio_member(studio_id) and status = 'unbilled');

-- DELETE — same: only your own unbilled entries.
create policy time_delete on time_entries for delete
  using (user_id = auth.uid() and is_studio_member(studio_id) and status = 'unbilled');

commit;

-- ════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- ════════════════════════════════════════════════════════════════

-- 1. New columns on studio_members, projects, time_entries (expect 6 rows).
select table_name, column_name, data_type, is_nullable, column_default
  from information_schema.columns
  where (table_name = 'studio_members' and column_name = 'hourly_rate')
     or (table_name = 'projects'       and column_name = 'time_taxable')
     or (table_name = 'time_entries'   and column_name in ('rate','status','invoice_line_item_id','billed_at'))
  order by table_name, column_name;

-- 2. CHECK constraints on time_entries (expect 2 rows).
select conname, pg_get_constraintdef(oid) as definition
  from pg_constraint
  where conrelid = 'time_entries'::regclass
    and conname in ('time_entries_status_check', 'time_entries_billed_consistency');

-- 3. RLS policies on time_entries (expect 4 rows: select/insert/update/delete).
select policyname, cmd from pg_policies
  where tablename = 'time_entries' order by policyname;

-- 4. Indexes (expect 3 new).
select indexname, tablename from pg_indexes
  where indexname in ('idx_time_user_status','idx_time_project_status','idx_time_invoice_line_item')
  order by indexname;

-- 5. Backfill sanity check — all existing time_entries should have landed
--    in the default state: status='unbilled', invoice_line_item_id/billed_at null.
select count(*) as total_rows,
       count(*) filter (where status = 'unbilled')             as unbilled,
       count(*) filter (where invoice_line_item_id is null)    as no_invoice_link,
       count(*) filter (where billed_at is null)               as no_billed_at
  from time_entries;
