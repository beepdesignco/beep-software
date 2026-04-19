-- Email send log. One row per outgoing invoice email.
-- Used for: recency checks, reminder scheduling, audit.

create table if not exists invoice_sends (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  invoice_id          uuid not null references invoices(id) on delete cascade,
  type                text not null check (type in ('invoice','reminder','receipt','custom')),
  recipient_email     text not null,
  subject             text,
  resend_message_id   text,
  sent_at             timestamptz not null default now(),
  sent_by_user_id     uuid references auth.users(id)
);
create index if not exists idx_invoice_sends_invoice on invoice_sends(invoice_id);
create index if not exists idx_invoice_sends_studio  on invoice_sends(studio_id, sent_at desc);

alter table invoice_sends enable row level security;

drop policy if exists invoice_sends_select on invoice_sends;
drop policy if exists invoice_sends_insert on invoice_sends;

create policy invoice_sends_select on invoice_sends for select
  using (has_permission(studio_id, 'view_financials'));

create policy invoice_sends_insert on invoice_sends for insert
  with check (has_permission(studio_id, 'send_invoices'));
