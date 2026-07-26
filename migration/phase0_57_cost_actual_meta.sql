-- Cost-actual logging metadata (notes, card, who ordered, when logged) for
-- the new "Log cost actual" modal flow. STRICTLY ADDITIVE: the existing
-- cost_actual / cost_actual_payment_method columns keep every value Baylor
-- and Olivia have entered — dashboard + budget math read them unchanged.
-- Meta is null for historical entries; they render in view mode with just
-- their amount.

begin;

alter table proposal_items
  add column if not exists cost_actual_meta jsonb;

alter table proposal_components
  add column if not exists cost_actual_meta jsonb;

commit;

select table_name, column_name from information_schema.columns
  where column_name = 'cost_actual_meta';
