-- can_run_payroll: lets a designated member (e.g. a bookkeeper) see the
-- Payroll tab and finalize pay periods without being the studio owner.
-- Default false — nothing changes for existing members. has_permission()
-- learns the new flag; payroll_runs RLS opens to flag-holders (owner keeps
-- full access via the role='owner' arm of has_permission).

begin;

alter table studio_members
  add column if not exists can_run_payroll boolean not null default false;

create or replace function has_permission(target_studio uuid, perm text)
returns boolean language sql security definer stable
set search_path = public, auth as $$
  select exists (
    select 1 from public.studio_members
    where studio_id = target_studio
      and user_id = auth.uid()
      and (
        role = 'owner'
        or (perm = 'view_financials'  and can_view_financials)
        or (perm = 'record_payments'  and can_record_payments)
        or (perm = 'send_invoices'    and can_send_invoices)
        or (perm = 'manage_expenses'  and can_manage_expenses)
        or (perm = 'manage_members'   and can_manage_members)
        or (perm = 'run_payroll'      and can_run_payroll)
      )
  );
$$;

-- Extend the privileged-fields freeze (phase0_48) so a member can't
-- self-grant payroll access via the API — the trigger blocklists columns
-- explicitly, so every new can_* flag must be added here.
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
  if NEW.pay_rate                    is distinct from OLD.pay_rate
  or NEW.hourly_rate                 is distinct from OLD.hourly_rate
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

drop policy if exists payroll_runs_all on payroll_runs;
create policy payroll_runs_all on payroll_runs for all
  using (has_permission(studio_id, 'run_payroll'))
  with check (has_permission(studio_id, 'run_payroll'));

commit;

select column_name from information_schema.columns
  where table_name = 'studio_members' and column_name = 'can_run_payroll';
