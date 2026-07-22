-- Lock member rates / role / permissions to the studio OWNER.
--
-- studio_members UPDATE RLS is (is_studio_owner OR user_id = auth.uid()) so a
-- member can update their OWN row — which is needed for self-profile + theme
-- preferences, but ALSO (before this) let a member change their own pay_rate,
-- billable rate, role, or permission flags via the API (the UI hid the inputs,
-- but RLS didn't stop a direct call). A member could even self-grant
-- permissions. This trigger closes that: a NON-owner may still edit harmless
-- self fields (display_name, job_title, phone, preferences), but any change to
-- rates, role, identity, or a permission flag is rejected unless the caller is
-- the studio owner.

create or replace function protect_studio_member_privileged()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- The owner may change anything on any member row.
  if is_studio_owner(OLD.studio_id) then
    return NEW;
  end if;
  -- Non-owner: freeze the privileged columns.
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
  then
    raise exception 'Only the studio owner can change member rates, role, or permissions'
      using errcode = '42501';
  end if;
  return NEW;
end $$;

drop trigger if exists trg_protect_studio_member_privileged on studio_members;
create trigger trg_protect_studio_member_privileged
  before update on studio_members
  for each row execute function protect_studio_member_privileged();
