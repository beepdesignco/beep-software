-- Daily auto-reminder job. Uses pg_cron + pg_net to POST to the Edge Function.
-- Run once per day at 14:00 UTC ≈ 9am Central (8am during daylight saving).
--
-- Prereqs: pg_cron + pg_net must be enabled in the Supabase dashboard
-- (Database → Extensions). Service-role key stored as a DB secret via Vault
-- or hard-coded here (not ideal). Simplest: store the URL + service-role key
-- in a dedicated config table.

-- Enable extensions (no-op if already enabled)
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- One-row config table holds the project URL + service role key for cron callers.
-- INSERT your own row manually after running this migration — see comment below.
create table if not exists app_config (
  key   text primary key,
  value text not null
);

-- After running this file, run ONCE (replace with real values):
--   insert into app_config (key, value) values
--     ('supabase_url', 'https://hceoxzzybzrjeqhwhvxf.supabase.co'),
--     ('service_role_key', '<SERVICE_ROLE_JWT>');
--
-- (Or edit existing rows if they're already present.)

-- Wrapper function: fetches the URL + key, calls the Edge Function via pg_net.
create or replace function run_invoice_reminders_cron()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_key text;
  v_request_id bigint;
begin
  select value into v_url from public.app_config where key = 'supabase_url';
  select value into v_key from public.app_config where key = 'service_role_key';
  if v_url is null or v_key is null then
    raise exception 'Missing supabase_url or service_role_key in app_config';
  end if;

  select net.http_post(
    url     := v_url || '/functions/v1/run-invoice-reminders',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_key,
      'Content-Type',  'application/json'
    ),
    body    := '{}'::jsonb
  ) into v_request_id;

  return v_request_id;
end
$$;

-- Schedule: daily at 14:00 UTC. If a schedule with this name already exists, unschedule first.
do $$
begin
  perform cron.unschedule('run-invoice-reminders-daily')
    where exists (select 1 from cron.job where jobname = 'run-invoice-reminders-daily');
exception when others then null;
end $$;

select cron.schedule(
  'run-invoice-reminders-daily',
  '0 14 * * *',
  $$ select run_invoice_reminders_cron(); $$
);
