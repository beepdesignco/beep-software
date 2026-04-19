-- Stripe integration schema additions.

-- Invoices: public payment token (used in /pay/?t=... URLs)
alter table invoices
  add column if not exists payment_token uuid,
  add column if not exists stripe_checkout_session_id text;

create unique index if not exists invoices_payment_token_unique
  on invoices(payment_token) where payment_token is not null;

-- Generate tokens for any existing non-cancelled invoices
update invoices
  set payment_token = gen_random_uuid()
  where payment_token is null and deleted_at is null and status <> 'draft';
