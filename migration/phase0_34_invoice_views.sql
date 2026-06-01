-- Phase 0, step 34 — invoice_views table.
--
-- Tracks when a client opens the client-facing payment page (pay/?t=<token>).
-- One row per non-bot view; the get-invoice-for-payment edge function inserts
-- a row each time it serves a token that matches an invoice. Email-client
-- prefetches (GoogleImageProxy, Outlook, Slack, etc.) are filtered out at
-- the edge function so the counts reflect actual human opens.
--
-- The web app reads these into S.invoices[i].views and displays a "Viewed N×"
-- pill (with a click-to-expand timestamp log) below the invoice total in the
-- builder.
--
-- Idempotent.

begin;

create table if not exists invoice_views (
  id         uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references invoices(id) on delete cascade,
  studio_id  uuid not null references studios(id) on delete cascade,
  viewed_at  timestamptz not null default now(),
  user_agent text,
  ip         text
);

create index if not exists invoice_views_invoice_id_idx on invoice_views (invoice_id, viewed_at desc);
create index if not exists invoice_views_studio_id_idx on invoice_views (studio_id);

-- RLS: each studio reads only its own view rows. Inserts come from the
-- service role (edge function), so no insert policy needed for end users.
alter table invoice_views enable row level security;

drop policy if exists invoice_views_select_own_studio on invoice_views;
create policy invoice_views_select_own_studio on invoice_views
  for select
  using (studio_id in (select studio_id from studio_members where user_id = auth.uid()));

commit;

-- Verify
select 'invoice_views table' as check, count(*) as exists
  from information_schema.tables where table_name = 'invoice_views';
