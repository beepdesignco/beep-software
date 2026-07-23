-- Enable Supabase Realtime on the freight-actual tables so a freight actual
-- entered by one user — including one whose net is SPLIT across multiple
-- proposal items via freight_actual_allocations — appears on another user's
-- screen (Budget → Freight math, PM item reconciliation strip) without a
-- manual refresh. Root cause of the 2026-07-22 bug: Olivia's split entries
-- saved durably (RLS is member-permissive on both tables) but Baylor's open
-- session never heard about them because neither table was in the publication.
--
-- Equivalent UI step: Supabase Studio → Database → Replication →
-- supabase_realtime → toggle freight_actuals / freight_actual_allocations on.

begin;

do $$
declare t text;
begin
  foreach t in array array['freight_actuals','freight_actual_allocations'] loop
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
    and tablename in ('freight_actuals','freight_actual_allocations');
