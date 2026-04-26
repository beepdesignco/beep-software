-- Phase 0, step 13 — U-Freight cleanup: retire componentType='shipping'.
--
-- After Phase 2, freight on a component lives in freight_charges (not on
-- the componentType label). The 'shipping' label is now redundant and
-- confusing alongside the new freight model. Convert any existing
-- 'shipping' components into 'other' (preserving their netCost in the
-- subtotal — they were already being summed there post-Phase-2).
--
-- The 'shipping' enum entry is also being removed from COMPONENT_TYPES in
-- the app, so the dropdown will no longer offer it.
--
-- Idempotent.

begin;

update proposal_components
  set component_type = 'other'
  where component_type = 'shipping';

commit;

-- Verification (expect 0).
select count(*) as remaining_shipping
  from proposal_components
  where component_type = 'shipping';
