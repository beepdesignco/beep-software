-- Phase 0, step 39 — Consolidate freight_charges.state: known → allowance.
--
-- Baylor's mental model treats "known" and "allowance" as the same thing
-- on freight, with "known" being too easy to confuse with "actual." Going
-- forward, the picker only offers Deferred / Allowance / None; this
-- migration converts any historical 'known' rows to 'allowance' so the
-- data and the UI agree.
--
-- The CHECK constraint on freight_charges_state_chk still allows both
-- values (we don't drop it — keeping 'known' as a permitted value is
-- backwards-compatible and lets the JS state-badge code fall back
-- gracefully if any legacy write slips through).
--
-- Idempotent.

begin;

update freight_charges
   set state = 'allowance'
 where state = 'known';

commit;

-- Verify
select state, count(*) as n
  from freight_charges
 group by state
 order by state;
