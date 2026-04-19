-- Invoice line item enhancements (Stripe prep):
--  - description: optional free-text shown below the name on the client-facing invoice/payment page
--  - proposal_component_id: when a user picks specific components of a constructed proposal item
--    rather than the whole item, each selected component becomes its own line item

alter table invoice_line_items
  add column if not exists description text,
  add column if not exists proposal_component_id uuid references proposal_components(id) on delete set null;

create index if not exists idx_inv_lines_proposal_comp
  on invoice_line_items(proposal_component_id) where proposal_component_id is not null;
