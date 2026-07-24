-- Per-line credit coverage with optional client-facing invisibility.
-- client_hidden: the line (and its covering credit line, also flagged) is
-- excluded from client-facing documents (PDF, email, pay page). A hidden
-- pair must net to zero INCLUDING the line's tax share, so client-visible
-- subtotal/tax/total stay arithmetically consistent. Internal records keep
-- everything: the sale, the tax (still filed), and the credit burn.
-- covers_line_id: links a credit line to the line it covers, so removing
-- either cleans up its partner.

begin;

alter table invoice_line_items
  add column if not exists client_hidden boolean not null default false,
  add column if not exists covers_line_id uuid;

commit;

select column_name from information_schema.columns
  where table_name = 'invoice_line_items' and column_name in ('client_hidden','covers_line_id');
