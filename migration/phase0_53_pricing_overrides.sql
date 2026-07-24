-- Three additive pricing columns (2026-07-23):
--  1. item_types.default_markup_pct — optional per-category default markup.
--     Resolution: item override > category default > project default. NULL
--     (all existing rows) = today's behavior exactly.
--  2. proposal_items.client_price_override + proposal_components.
--     client_price_override — direct "client pays $X" override that
--     bypasses markup math (item: per-unit for readymade/openline, total
--     for constructed; component: line total).
--  3. freight_categories.flat_rate — optional flat $ pre-filled when
--     logging a freight actual in that category (e.g. $35 Receiving fee).

begin;

alter table item_types
  add column if not exists default_markup_pct numeric;

alter table proposal_items
  add column if not exists client_price_override numeric;

alter table proposal_components
  add column if not exists client_price_override numeric;

alter table freight_categories
  add column if not exists flat_rate numeric;

commit;

select table_name, column_name from information_schema.columns
  where (table_name, column_name) in (
    ('item_types','default_markup_pct'),
    ('proposal_items','client_price_override'),
    ('proposal_components','client_price_override'),
    ('freight_categories','flat_rate'));
