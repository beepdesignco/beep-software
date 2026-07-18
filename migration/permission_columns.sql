-- Two new per-member permission flags on studio_members.
--
--   can_edit_project_settings — false = the Project Settings modal (incl. the
--     project's tax rate) and the studio State/Tax settings are read-only for
--     this member.
--   can_edit_invoices — false = the invoice builder is view-only for this member
--     (they can open and read invoices, and — if can_record_payments is on —
--     still log payments, but cannot add/edit/remove line items, save, send, or
--     create invoices).
--
-- Both DEFAULT TRUE so existing members keep full edit access. The app also
-- treats a NULL/absent value as "allowed" (it only ever restricts on an
-- explicit false), so running this migration cannot lock anyone out — a member
-- becomes restricted only when you flip the flag off in App Settings → Team.
--
-- Owners always bypass these flags regardless of column value.
-- Safe to re-run: IF NOT EXISTS guards every add.

ALTER TABLE public.studio_members
  ADD COLUMN IF NOT EXISTS can_edit_project_settings boolean NOT NULL DEFAULT true;

ALTER TABLE public.studio_members
  ADD COLUMN IF NOT EXISTS can_edit_invoices boolean NOT NULL DEFAULT true;
