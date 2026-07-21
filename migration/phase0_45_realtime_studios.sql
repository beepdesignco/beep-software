-- Enable Supabase Realtime on the studios table.
--
-- So a change to shared settings (vendor/brand categories, vendor types, status
-- config, etc.) made by one user propagates to every other signed-in user
-- without a manual refresh — and keeps each client's sync shadow current so the
-- whole-blob writer can't clobber another user's additions.
--
-- Equivalent UI step: Supabase Studio → Database → Replication →
-- supabase_realtime → toggle studios on.

begin;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'studios'
  ) then
    execute 'alter publication supabase_realtime add table public.studios';
  end if;
end $$;

commit;

select schemaname, tablename
  from pg_publication_tables
  where pubname = 'supabase_realtime' and tablename = 'studios';
