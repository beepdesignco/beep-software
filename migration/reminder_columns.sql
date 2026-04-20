-- Reminders: per-invoice override of the studio default schedule.
-- Studio-level defaults live on studios.studio_info.reminderDefaults (jsonb under studio_info).

alter table invoices add column if not exists reminder_override jsonb;
