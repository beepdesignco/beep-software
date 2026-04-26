-- Phase 0, step 12 — U-Freight follow-up: constructed items can't carry
-- item-level freight charges (freight lives per-component on constructed
-- items). Drop any existing freight_charges rows where parent_type='item'
-- and the parent item has type='constructed'.
--
-- Test data only — confirmed safe.
--
-- Idempotent.

begin;

delete from freight_charges
  where id in (
    select fc.id
    from freight_charges fc
    join proposal_items pi on pi.id = fc.parent_id
    where fc.parent_type = 'item' and pi.type = 'constructed'
  );

commit;

-- Verification (expect 0).
select count(*) as constructed_with_item_freight
  from freight_charges fc
  join proposal_items pi on pi.id = fc.parent_id
  where fc.parent_type = 'item' and pi.type = 'constructed';
