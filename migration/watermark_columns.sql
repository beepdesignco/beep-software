-- Phase: watermark toggle per invoice.
alter table invoices add column if not exists watermark_mode text;
