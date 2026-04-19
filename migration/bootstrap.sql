-- Bootstrap Beep Design studio with Baylor as owner.
-- Run ONCE after schema.sql + rls.sql + creating the auth user via Supabase Auth → Users.
-- The SQL Editor runs as the postgres role which bypasses RLS, so this works despite the insert policies.

-- If you used a different email when creating your Supabase auth user, change this line:
--   baylor_email := 'your-actual-email@example.com';

do $$
declare
  baylor_email  text := 'baylor@beepdesign.co';
  baylor_id     uuid;
  new_studio_id uuid;
begin
  select id into baylor_id from auth.users where email = baylor_email limit 1;

  if baylor_id is null then
    raise exception 'No auth user found with email %. Create the user via Authentication → Users first.', baylor_email;
  end if;

  -- Avoid re-bootstrapping if a studio already exists for this owner
  if exists (select 1 from studios where owner_user_id = baylor_id) then
    raise notice 'A studio already exists for this owner. Bootstrap skipped.';
    return;
  end if;

  insert into studios (name, owner_user_id, studio_info)
  values (
    'Beep Design',
    baylor_id,
    jsonb_build_object(
      'name',    'Beep Design',
      'email',   baylor_email,
      'website', 'beepdesign.co'
    )
  )
  returning id into new_studio_id;

  insert into studio_members (
    studio_id, user_id, role, display_name, job_title,
    can_view_financials, can_record_payments, can_send_invoices,
    can_manage_expenses, can_manage_members,
    accepted_at
  )
  values (
    new_studio_id, baylor_id, 'owner', 'Baylor', 'Owner',
    true, true, true,
    true, true,
    now()
  );

  raise notice 'Bootstrap complete. Studio id: %. Owner id: %.', new_studio_id, baylor_id;
end $$;

-- Verify
select s.id as studio_id, s.name, sm.role, sm.display_name, u.email
from studios s
join studio_members sm on sm.studio_id = s.id
join auth.users u on u.id = sm.user_id;
