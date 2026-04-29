-- Phase 0, step 29 — enable Supabase Realtime on expenses.
--
-- Same pattern as phase0_28 (time_entries). Mobile creates expenses
-- via the Log Expense sheet; web subscribes to postgres_changes on
-- the expenses table and pops new rows into S.expenses without a
-- manual reload.
--
-- Idempotent.

begin;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'expenses'
  ) then
    execute 'alter publication supabase_realtime add table public.expenses';
  end if;
end $$;

commit;

select schemaname, tablename
  from pg_publication_tables
  where pubname = 'supabase_realtime'
    and tablename = 'expenses';
