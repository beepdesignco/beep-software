-- Realtime on the contacts/address-book tables so one user's vendor, brand,
-- rep, and brand-link work appears in the other's session without a reload
-- (previously these were load-once: visible only after refresh).
--
-- vendor_brands is composite-PK (vendor_id, brand_id) with default replica
-- identity = PK, which is exactly what DELETE payloads need.
--
-- Equivalent UI step: Supabase Studio → Database → Replication →
-- supabase_realtime → toggle each table on.

begin;

do $$
declare t text;
begin
  foreach t in array array['vendors','vendor_contacts','brands','vendor_brands'] loop
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
    and tablename in ('vendors','vendor_contacts','brands','vendor_brands');
