-- Phase 0, step 31 — lead-time tracking on items + components, install date on projects.
--
-- Project gets a soft "install date" (the target install day, or "week of",
-- or "month of", with no migration required when precision is unknown).
-- Items get a lead-time window (min/max weeks) plus a start-date trigger:
-- when the item flips to status='ordered' the first time, ordered_at is
-- stamped; the lead-time clock runs from there. A manual override
-- (lead_time_start_manual) always wins.
--
-- Components get the same lead-time pair plus a stage number (1-indexed)
-- so constructed items can stack parallel work into sequential phases.
-- All components in a stage run in parallel; the next stage can't start
-- until every component in the prior stage has arrived. Total lead time
-- for a constructed item = sum of (longest lead time per stage).
--
-- All new columns are nullable / default-permissive so existing rows
-- remain valid without a backfill.
--
-- Idempotent.

begin;

-- Projects: install date (the target on-site / installation day).
-- install_date_precision drives the display: 'day' shows the exact date,
-- 'week' shows "Week of ...", 'month' shows the month name. NULL = unset.
alter table projects
  add column if not exists install_date_value     date,
  add column if not exists install_date_precision text;

alter table projects drop constraint if exists projects_install_date_precision_chk;
alter table projects
  add constraint projects_install_date_precision_chk
  check (install_date_precision is null or install_date_precision in ('day','week','month'));

-- Items: lead-time window + start-date trigger.
alter table proposal_items
  add column if not exists lead_time_weeks_min    integer,
  add column if not exists lead_time_weeks_max    integer,
  add column if not exists lead_time_start_manual date,
  add column if not exists ordered_at             date;

alter table proposal_items drop constraint if exists proposal_items_lead_time_weeks_chk;
alter table proposal_items
  add constraint proposal_items_lead_time_weeks_chk
  check (
    (lead_time_weeks_min is null and lead_time_weeks_max is null)
    or (lead_time_weeks_min >= 0 and lead_time_weeks_max >= lead_time_weeks_min)
  );

-- Components: lead-time window + stage assignment (1-indexed; 1 = first phase).
alter table proposal_components
  add column if not exists lead_time_weeks_min    integer,
  add column if not exists lead_time_weeks_max    integer,
  add column if not exists lead_time_stage        integer,
  add column if not exists lead_time_start_manual date;

alter table proposal_components drop constraint if exists proposal_components_lead_time_weeks_chk;
alter table proposal_components
  add constraint proposal_components_lead_time_weeks_chk
  check (
    (lead_time_weeks_min is null and lead_time_weeks_max is null)
    or (lead_time_weeks_min >= 0 and lead_time_weeks_max >= lead_time_weeks_min)
  );

alter table proposal_components drop constraint if exists proposal_components_lead_time_stage_chk;
alter table proposal_components
  add constraint proposal_components_lead_time_stage_chk
  check (lead_time_stage is null or lead_time_stage >= 1);

commit;

-- Verify
select column_name, data_type, is_nullable from information_schema.columns
  where (table_name, column_name) in (
    ('projects', 'install_date_value'),
    ('projects', 'install_date_precision'),
    ('proposal_items',      'lead_time_weeks_min'),
    ('proposal_items',      'lead_time_weeks_max'),
    ('proposal_items',      'lead_time_start_manual'),
    ('proposal_items',      'ordered_at'),
    ('proposal_components', 'lead_time_weeks_min'),
    ('proposal_components', 'lead_time_weeks_max'),
    ('proposal_components', 'lead_time_stage'),
    ('proposal_components', 'lead_time_start_manual')
  )
  order by table_name, column_name;
