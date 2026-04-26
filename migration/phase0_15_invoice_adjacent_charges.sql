-- Phase 0, step 15 — U-Freight Phase 5 Part 1: invoice adjacent charges.
--
-- Splits the invoice's combined freight number into two distinct invoice
-- lines: primary Freight (existing invoices.freight) and Other associated
-- charges (new invoices.adjacent_charges). Adjacent charges have per-
-- category tax rules, so we also store the auto-computed taxable amount
-- alongside the gross — gates by both project.tax_freight AND each
-- source category's is_taxable.
--
-- Idempotent.

begin;

alter table invoices
  add column if not exists adjacent_charges                numeric(12,2) not null default 0,
  add column if not exists adjacent_charges_taxable_amount numeric(12,2) not null default 0;

commit;

-- Verification
select column_name, data_type, is_nullable, column_default
  from information_schema.columns
  where table_name = 'invoices'
    and column_name in ('adjacent_charges', 'adjacent_charges_taxable_amount')
  order by column_name;
