-- RLS hardening round 1 (audit 2026-07-25): close the gaps where the UI
-- promises a restriction the database doesn't enforce. Scoped to changes
-- that DON'T disturb current legitimate use:
--   GAP-1: can_edit_invoices now gates invoice + line-item writes
--          (flag defaults true; Olivia keeps full CRUD).
--   GAP-4: expenses writes gate on can_manage_expenses, with a one-time
--          backfill granting it to every member who currently has
--          can_view_financials (they could already write — no behavior
--          change today, enforceable going forward).
--   GAP-6: editing/deleting your own unbilled time requires
--          can_adjust_time_entries (defaults true).
--   GAP-7: invoice_views SELECT requires view_financials.
-- GAP-2 (send-email server check) ships in the edge function.
-- GAP-3 (pay-rate readability) + GAP-5 (settings blob split) are design
-- refactors — deferred for explicit sign-off.

begin;

-- has_permission learns edit_invoices + adjust_time (keeps run_payroll
-- from phase0_55 and the owner short-circuit).
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
        or (perm = 'edit_invoices'    and can_edit_invoices is not false)
        or (perm = 'adjust_time'      and can_adjust_time_entries is not false)
      )
  );
$$;

-- GAP-1: invoices — SELECT stays view_financials; writes require
-- edit_invoices. (invoices_select already exists from rls.sql.)
drop policy if exists invoices_modify on invoices;
create policy invoices_insert on invoices for insert
  with check (has_permission(studio_id, 'edit_invoices'));
create policy invoices_update on invoices for update
  using (has_permission(studio_id, 'edit_invoices'))
  with check (has_permission(studio_id, 'edit_invoices'));
create policy invoices_delete on invoices for delete
  using (has_permission(studio_id, 'edit_invoices'));

drop policy if exists inv_lines_all on invoice_line_items;
create policy inv_lines_select on invoice_line_items for select
  using (has_permission(studio_of_invoice(invoice_id), 'view_financials'));
create policy inv_lines_insert on invoice_line_items for insert
  with check (has_permission(studio_of_invoice(invoice_id), 'edit_invoices'));
create policy inv_lines_update on invoice_line_items for update
  using (has_permission(studio_of_invoice(invoice_id), 'edit_invoices'))
  with check (has_permission(studio_of_invoice(invoice_id), 'edit_invoices'));
create policy inv_lines_delete on invoice_line_items for delete
  using (has_permission(studio_of_invoice(invoice_id), 'edit_invoices'));

-- GAP-4: expenses — backfill first so nobody loses access they use today.
update studio_members
  set can_manage_expenses = true
  where can_view_financials = true and role <> 'owner' and can_manage_expenses = false;

drop policy if exists expenses_modify on expenses;
create policy expenses_insert on expenses for insert
  with check (has_permission(studio_id, 'manage_expenses'));
create policy expenses_update on expenses for update
  using (has_permission(studio_id, 'manage_expenses'))
  with check (has_permission(studio_id, 'manage_expenses'));
create policy expenses_delete on expenses for delete
  using (has_permission(studio_id, 'manage_expenses'));

-- GAP-6: self-edits of unbilled PAST time require the adjust flag
-- (defaults true — only explicitly-restricted members are affected).
-- The RUNNING-timer lifecycle is carved out via companion policies: stop
-- finalizes and cancel deletes your own running row (ended_at is null),
-- and that must keep working for everyone or the timer breaks.
drop policy if exists time_update on time_entries;
create policy time_update on time_entries for update
  using (
    is_studio_member(studio_id) and status = 'unbilled'
    and ((user_id = auth.uid() and has_permission(studio_id, 'adjust_time'))
         or is_studio_owner(studio_id))
  )
  with check (
    is_studio_member(studio_id) and status = 'unbilled'
    and ((user_id = auth.uid() and has_permission(studio_id, 'adjust_time'))
         or is_studio_owner(studio_id))
  );
create policy time_update_running_self on time_entries for update
  using (
    is_studio_member(studio_id) and status = 'unbilled'
    and user_id = auth.uid() and ended_at is null
  )
  with check (
    is_studio_member(studio_id) and status = 'unbilled'
    and user_id = auth.uid()
  );
drop policy if exists time_delete on time_entries;
create policy time_delete on time_entries for delete
  using (
    is_studio_member(studio_id) and status = 'unbilled'
    and ((user_id = auth.uid() and has_permission(studio_id, 'adjust_time'))
         or is_studio_owner(studio_id))
  );
create policy time_delete_running_self on time_entries for delete
  using (
    is_studio_member(studio_id) and status = 'unbilled'
    and user_id = auth.uid() and ended_at is null
  );

-- GAP-7: invoice open/view tracking follows the parent invoice's gate.
drop policy if exists invoice_views_select_own_studio on invoice_views;
create policy invoice_views_select_own_studio on invoice_views for select
  using (has_permission(studio_id, 'view_financials'));

commit;

select tablename, policyname from pg_policies
  where tablename in ('invoices','invoice_line_items','expenses','time_entries','invoice_views')
  order by tablename, policyname;
