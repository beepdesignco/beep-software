-- phase0_64 — un-bill time entries BEFORE an invoice line is deleted
--
-- Bug (2026-08-03, after §6A.1 made billed status persist): deleting an
-- invoice deletes its invoice_line_items rows; the FK
-- time_entries.invoice_line_item_id is ON DELETE SET NULL, which nulls the
-- link while status is still 'billed' → violates
-- time_entries_billed_consistency → the whole delete fails with
--   'new row for relation "time_entries" violates check constraint ...'
-- The app DOES revert entries in memory (revertTimeEntriesForInvoice), but
-- its time_entries write syncs AFTER the line delete, so the DB race always
-- loses. Fix at the source: BEFORE DELETE trigger resets the full billed
-- triple, so the FK's SET NULL finds nothing left to null.
--
-- SECURITY DEFINER + pinned search_path per the RLS-helper lesson; runs
-- regardless of which member performed the (already RLS-gated) delete.
-- Rollback: drop trigger trg_unbill_time_on_line_delete on invoice_line_items;
--           drop function public.unbill_time_on_line_delete();

begin;

create or replace function public.unbill_time_on_line_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.time_entries
     set status = 'unbilled',
         invoice_line_item_id = null,
         billed_at = null
   where invoice_line_item_id = old.id;
  return old;
end $$;

drop trigger if exists trg_unbill_time_on_line_delete on invoice_line_items;
create trigger trg_unbill_time_on_line_delete
  before delete on invoice_line_items
  for each row execute function public.unbill_time_on_line_delete();

commit;

select tgname from pg_trigger where tgname = 'trg_unbill_time_on_line_delete';
