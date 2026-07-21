-- Time + Payroll, Phase 1: two decoupled per-member rates on studio_members.
--
--   pay_rate     — what the studio PAYS this person per hour (their wage).
--                  Drives payroll: gross pay = clocked hours × pay_rate.
--                  Independent of client billing.
--   hourly_rate  — the BILLABLE rate charged to clients for this person's
--                  billable time (already used as the default rate on time
--                  entries). Kept as-is; added here IF NOT EXISTS for safety.
--
-- Both nullable (no default rate assumed). Payroll math simply skips a person
-- with no pay_rate set until the owner fills it in. Safe to re-run.

ALTER TABLE public.studio_members
  ADD COLUMN IF NOT EXISTS pay_rate numeric;

ALTER TABLE public.studio_members
  ADD COLUMN IF NOT EXISTS hourly_rate numeric;
