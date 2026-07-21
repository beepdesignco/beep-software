-- Enable Supabase Realtime on the proposal (PM) tables so item/component
-- changes — actual costs, statuses, PM info, adds/removes — made by one user
-- appear on another user's screen without a manual refresh.
--
-- Equivalent UI step: Supabase Studio → Database → Replication →
-- supabase_realtime → toggle proposal_items / proposal_components /
-- proposal_spaces on.

begin;

do $$
declare t text;
begin
  foreach t in array array['proposal_items','proposal_components','proposal_spaces'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

commit;

select tablename
  from pg_publication_tables
  where pubname = 'supabase_realtime'
    and tablename in ('proposal_items','proposal_components','proposal_spaces');
