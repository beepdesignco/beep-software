-- RLS hardening round 2 (Baylor-approved refactors from the 2026-07-25 audit):
--
-- GAP-3: pay_rate moves off studio_members (member-readable) into
-- member_rates, SELECT/write gated to owner + can_run_payroll. hourly_rate
-- (billable rate) stays member-readable — it's the default rate for time
-- entries and isn't sensitive. The studio_members.pay_rate column is
-- dropped in a FOLLOW-UP statement after the app deploy (live sessions
-- still select it until reload).
--
-- GAP-5: the studios.settings blob stays whole (shared-taxonomy saves by
-- members keep working, phase0_44 lesson) but a trigger freezes the
-- SENSITIVE keys inside it for non-owners: tax_states, tax_filings,
-- sales_tax_tracker_*. A member's whole-blob write with unchanged tax
-- values passes; any tampering with those keys via the API is rejected.

begin;

-- ── GAP-3: member_rates
create table if not exists member_rates (
  member_id uuid primary key references studio_members(id) on delete cascade,
  studio_id uuid not null references studios(id) on delete cascade,
  pay_rate numeric,
  updated_at timestamptz not null default now()
);

alter table member_rates enable row level security;

drop policy if exists member_rates_all on member_rates;
create policy member_rates_all on member_rates
  for all
  using (has_permission(studio_id, 'run_payroll'))
  with check (has_permission(studio_id, 'run_payroll'));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'member_rates_set_updated_at') then
    create trigger member_rates_set_updated_at before update on member_rates
      for each row execute function set_updated_at();
  end if;
end $$;

-- Copy existing wages across (idempotent).
insert into member_rates (member_id, studio_id, pay_rate)
  select id, studio_id, pay_rate from studio_members where pay_rate is not null
  on conflict (member_id) do update set pay_rate = excluded.pay_rate;

-- Privileged-fields freeze: pay_rate is leaving studio_members, so remove
-- it from the blocklist (member_rates has its own owner/payroll gate).
create or replace function protect_studio_member_privileged()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if is_studio_owner(OLD.studio_id) then
    return NEW;
  end if;
  if NEW.hourly_rate                 is distinct from OLD.hourly_rate
  or NEW.role                        is distinct from OLD.role
  or NEW.studio_id                   is distinct from OLD.studio_id
  or NEW.user_id                     is distinct from OLD.user_id
  or NEW.can_view_financials         is distinct from OLD.can_view_financials
  or NEW.can_record_payments         is distinct from OLD.can_record_payments
  or NEW.can_send_invoices           is distinct from OLD.can_send_invoices
  or NEW.can_manage_expenses         is distinct from OLD.can_manage_expenses
  or NEW.can_manage_members          is distinct from OLD.can_manage_members
  or NEW.can_adjust_time_entries     is distinct from OLD.can_adjust_time_entries
  or NEW.can_view_vendor_credentials is distinct from OLD.can_view_vendor_credentials
  or NEW.can_edit_project_settings   is distinct from OLD.can_edit_project_settings
  or NEW.can_edit_invoices           is distinct from OLD.can_edit_invoices
  or NEW.can_run_payroll             is distinct from OLD.can_run_payroll
  then
    raise exception 'Only the studio owner can change member rates, role, or permissions'
      using errcode = '42501';
  end if;
  return NEW;
end $$;

-- ── GAP-5: freeze sensitive settings keys for non-owners
create or replace function protect_studio_sensitive_settings()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if is_studio_owner(OLD.id) then
    return NEW;
  end if;
  if (NEW.settings->'tax_states')                    is distinct from (OLD.settings->'tax_states')
  or (NEW.settings->'tax_filings')                   is distinct from (OLD.settings->'tax_filings')
  or (NEW.settings->'sales_tax_tracker_enabled')     is distinct from (OLD.settings->'sales_tax_tracker_enabled')
  or (NEW.settings->'sales_tax_tracker_start_date')  is distinct from (OLD.settings->'sales_tax_tracker_start_date')
  then
    raise exception 'Only the studio owner can change tax settings'
      using errcode = '42501';
  end if;
  return NEW;
end $$;

drop trigger if exists trg_protect_studio_sensitive_settings on studios;
create trigger trg_protect_studio_sensitive_settings
  before update on studios
  for each row execute function protect_studio_sensitive_settings();

commit;

select (select count(*) from member_rates) as rates_copied,
       (select count(*) from pg_trigger where tgname = 'trg_protect_studio_sensitive_settings') as settings_trigger;
