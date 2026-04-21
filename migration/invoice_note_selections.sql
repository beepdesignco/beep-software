-- Which studio-level default-note presets are attached to this invoice.
-- Stored as a jsonb array of UUID strings (preset IDs). Composition with the
-- free-form invoices.notes happens client-side (in the app) or server-side
-- (in get-invoice-for-payment for the pay page + any future email cron).

alter table invoices add column if not exists note_selections jsonb not null default '[]'::jsonb;
