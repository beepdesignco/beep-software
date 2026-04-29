-- Phase 0, step 28 — enable Supabase Realtime on time_entries.
--
-- Adds the table to the supabase_realtime publication so postgres_changes
-- subscriptions fire for INSERT / UPDATE / DELETE. Mobile uses this to
-- show entries logged on the web (or another device) without a manual
-- refresh.
--
-- Equivalent UI step: Supabase Studio → Database → Replication →
-- supabase_realtime publication → toggle time_entries on. Either path
-- works; this SQL is the codified version.

begin;

-- Idempotent guard: only add if not already present.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'time_entries'
  ) then
    execute 'alter publication supabase_realtime add table public.time_entries';
  end if;
end $$;

commit;

select schemaname, tablename
  from pg_publication_tables
  where pubname = 'supabase_realtime'
    and tablename = 'time_entries';
