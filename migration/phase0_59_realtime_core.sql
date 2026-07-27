-- Realtime on the remaining high-traffic "load-once" tables so two users'
-- sessions stay in sync without reloads: projects (incl. the files jsonb —
-- the document-upload staleness), invoices (status/totals), invoice
-- payments (a payment recorded anywhere updates everyone), clients.
--
-- Equivalent UI step: Supabase Studio → Database → Replication →
-- supabase_realtime → toggle each table on.

begin;

do $$
declare t text;
begin
  foreach t in array array['projects','invoices','invoice_payments','clients'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

commit;

select tablename from pg_publication_tables
  where pubname = 'supabase_realtime'
    and tablename in ('projects','invoices','invoice_payments','clients');
