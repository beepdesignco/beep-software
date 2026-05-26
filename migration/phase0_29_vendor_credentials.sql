-- Phase 0, step 29 — Vendor credentials (encrypted username/password/account #).
--
-- Architecture:
--   • pgcrypto + Supabase Vault: master key stored in vault.secrets (encrypted
--     with a project-level key Postgres does not store in user tables).
--   • Encrypted bytea columns on vendors. Plaintext never touches the table.
--   • Read/write only via SECURITY DEFINER RPC functions, gated by
--     studio_members.can_view_vendor_credentials (owners auto-allowed).
--   • Every read/write/clear is appended to vendor_credential_access_log.
--
-- Loss of the Vault key = loss of every stored credential (no backdoor).
-- Back up the key once after running this migration (see verification block
-- at the bottom of the file).
--
-- Idempotent.

begin;

-- ════════════════════════════════════════════════════════════════
-- 1. Extensions
-- ════════════════════════════════════════════════════════════════
create extension if not exists pgcrypto;
-- The `vault` extension is enabled by default on Supabase projects.

-- ════════════════════════════════════════════════════════════════
-- 2. Permission column on studio_members
-- ════════════════════════════════════════════════════════════════
-- Defaults to FALSE: new members cannot see vendor credentials until an
-- owner toggles it on. Owners are always allowed regardless of this column
-- (the RPC functions check role='owner' first).
alter table studio_members
  add column if not exists can_view_vendor_credentials boolean not null default false;

-- ════════════════════════════════════════════════════════════════
-- 3. Encrypted columns on vendors
-- ════════════════════════════════════════════════════════════════
-- All three fields encrypted: the username + account number combined with
-- the password constitute the credential, so all three deserve the same
-- protection. Anyone with table SELECT sees only ciphertext.
alter table vendors
  add column if not exists credentials_username_enc    bytea,
  add column if not exists credentials_password_enc    bytea,
  add column if not exists credentials_account_enc     bytea,
  add column if not exists credentials_updated_at      timestamptz,
  add column if not exists credentials_updated_by      uuid references auth.users(id);

-- ════════════════════════════════════════════════════════════════
-- 4. Vault secret (one-time, idempotent)
-- ════════════════════════════════════════════════════════════════
-- Stores a 256-bit random key. The key is deliberately NOT logged here —
-- retrieve it once via the verification block below and store it offline
-- (1Password / Bitwarden). If Supabase loses the Vault, this backup is the
-- only way to decrypt existing credentials.
do $$
declare
  v_key text;
begin
  if not exists (select 1 from vault.secrets where name = 'beep_vendor_credentials_key') then
    v_key := encode(gen_random_bytes(32), 'base64');
    perform vault.create_secret(
      v_key,
      'beep_vendor_credentials_key',
      'BEEP HQ — vendor credentials encryption key (do not lose: backed up to 1Password)'
    );
  end if;
end $$;

-- ════════════════════════════════════════════════════════════════
-- 5. Audit log
-- ════════════════════════════════════════════════════════════════
-- Append-only record of who decrypted/encrypted/cleared which credential
-- and when. Inserts happen exclusively from the SECURITY DEFINER RPC
-- functions; direct INSERT is forbidden by policy so client code cannot
-- forge entries. SELECT is restricted to studio owners.
create table if not exists vendor_credential_access_log (
  id          uuid primary key default gen_random_uuid(),
  studio_id   uuid not null references studios(id) on delete cascade,
  vendor_id   uuid not null references vendors(id) on delete cascade,
  user_id     uuid not null references auth.users(id),
  action      text not null check (action in ('read','write','clear')),
  occurred_at timestamptz not null default now()
);

create index if not exists idx_vcal_studio_time on vendor_credential_access_log(studio_id, occurred_at desc);
create index if not exists idx_vcal_vendor_time on vendor_credential_access_log(vendor_id, occurred_at desc);

alter table vendor_credential_access_log enable row level security;

drop policy if exists vcal_select on vendor_credential_access_log;
create policy vcal_select on vendor_credential_access_log for select
  using (is_studio_owner(studio_id));

drop policy if exists vcal_no_direct_insert on vendor_credential_access_log;
create policy vcal_no_direct_insert on vendor_credential_access_log for insert
  with check (false);

drop policy if exists vcal_no_update on vendor_credential_access_log;
create policy vcal_no_update on vendor_credential_access_log for update
  using (false);

drop policy if exists vcal_no_delete on vendor_credential_access_log;
create policy vcal_no_delete on vendor_credential_access_log for delete
  using (false);

-- ════════════════════════════════════════════════════════════════
-- 6. RPC functions
-- ════════════════════════════════════════════════════════════════

-- get_vendor_credentials: returns plaintext IFF caller has permission.
drop function if exists get_vendor_credentials(uuid);
create function get_vendor_credentials(p_vendor_id uuid)
returns table(username text, password text, account_number text, updated_at timestamptz)
language plpgsql
security definer
set search_path = public, vault, pg_temp
as $$
declare
  v_key       text;
  v_studio_id uuid;
  v_allowed   boolean;
begin
  select studio_id into v_studio_id from public.vendors where id = p_vendor_id;
  if v_studio_id is null then
    raise exception 'Vendor not found' using errcode = '42704';
  end if;

  select (role = 'owner' or can_view_vendor_credentials)
    into v_allowed
    from public.studio_members
    where studio_id = v_studio_id and user_id = auth.uid();

  if v_allowed is not true then
    raise exception 'Permission denied: vendor credentials' using errcode = '42501';
  end if;

  select decrypted_secret into v_key
    from vault.decrypted_secrets
    where name = 'beep_vendor_credentials_key';

  if v_key is null then
    raise exception 'Vault key beep_vendor_credentials_key not found';
  end if;

  insert into public.vendor_credential_access_log (studio_id, vendor_id, user_id, action)
    values (v_studio_id, p_vendor_id, auth.uid(), 'read');

  return query
    select
      case when v.credentials_username_enc is null then null::text
           else pgp_sym_decrypt(v.credentials_username_enc, v_key) end,
      case when v.credentials_password_enc is null then null::text
           else pgp_sym_decrypt(v.credentials_password_enc, v_key) end,
      case when v.credentials_account_enc is null then null::text
           else pgp_sym_decrypt(v.credentials_account_enc, v_key) end,
      v.credentials_updated_at
    from public.vendors v
    where v.id = p_vendor_id;
end $$;

-- set_vendor_credentials: encrypt and store. Empty/NULL inputs clear that field.
drop function if exists set_vendor_credentials(uuid, text, text, text);
create function set_vendor_credentials(
  p_vendor_id      uuid,
  p_username       text,
  p_password       text,
  p_account_number text
) returns void
language plpgsql
security definer
set search_path = public, vault, pg_temp
as $$
declare
  v_key       text;
  v_studio_id uuid;
  v_allowed   boolean;
begin
  select studio_id into v_studio_id from public.vendors where id = p_vendor_id;
  if v_studio_id is null then
    raise exception 'Vendor not found' using errcode = '42704';
  end if;

  select (role = 'owner' or can_view_vendor_credentials)
    into v_allowed
    from public.studio_members
    where studio_id = v_studio_id and user_id = auth.uid();

  if v_allowed is not true then
    raise exception 'Permission denied: vendor credentials' using errcode = '42501';
  end if;

  select decrypted_secret into v_key
    from vault.decrypted_secrets
    where name = 'beep_vendor_credentials_key';

  if v_key is null then
    raise exception 'Vault key beep_vendor_credentials_key not found';
  end if;

  update public.vendors set
    credentials_username_enc = case when p_username is null or p_username = '' then null
                                    else pgp_sym_encrypt(p_username, v_key) end,
    credentials_password_enc = case when p_password is null or p_password = '' then null
                                    else pgp_sym_encrypt(p_password, v_key) end,
    credentials_account_enc  = case when p_account_number is null or p_account_number = '' then null
                                    else pgp_sym_encrypt(p_account_number, v_key) end,
    credentials_updated_at   = now(),
    credentials_updated_by   = auth.uid()
    where id = p_vendor_id;

  insert into public.vendor_credential_access_log (studio_id, vendor_id, user_id, action)
    values (v_studio_id, p_vendor_id, auth.uid(), 'write');
end $$;

-- clear_vendor_credentials: removes all three encrypted fields.
drop function if exists clear_vendor_credentials(uuid);
create function clear_vendor_credentials(p_vendor_id uuid)
returns void
language plpgsql
security definer
set search_path = public, vault, pg_temp
as $$
declare
  v_studio_id uuid;
  v_allowed   boolean;
begin
  select studio_id into v_studio_id from public.vendors where id = p_vendor_id;
  if v_studio_id is null then
    raise exception 'Vendor not found' using errcode = '42704';
  end if;

  select (role = 'owner' or can_view_vendor_credentials)
    into v_allowed
    from public.studio_members
    where studio_id = v_studio_id and user_id = auth.uid();

  if v_allowed is not true then
    raise exception 'Permission denied: vendor credentials' using errcode = '42501';
  end if;

  update public.vendors set
    credentials_username_enc = null,
    credentials_password_enc = null,
    credentials_account_enc  = null,
    credentials_updated_at   = now(),
    credentials_updated_by   = auth.uid()
    where id = p_vendor_id;

  insert into public.vendor_credential_access_log (studio_id, vendor_id, user_id, action)
    values (v_studio_id, p_vendor_id, auth.uid(), 'clear');
end $$;

-- ════════════════════════════════════════════════════════════════
-- 7. Grants
-- ════════════════════════════════════════════════════════════════
grant execute on function
  get_vendor_credentials(uuid),
  set_vendor_credentials(uuid, text, text, text),
  clear_vendor_credentials(uuid)
  to authenticated;

commit;

-- ────────────────────────────────────────────────────────────────
-- Verification — run these AFTER the migration commits.
-- ────────────────────────────────────────────────────────────────
-- 1. Permission column present + default false:
--      select column_name, data_type, column_default from information_schema.columns
--      where table_name='studio_members' and column_name='can_view_vendor_credentials';
--
-- 2. Vault secret exists (DO NOT log the decrypted value to a shared system):
--      select id, name, created_at from vault.secrets where name='beep_vendor_credentials_key';
--
-- 3. BACK UP THE KEY (one time only). Copy the result into 1Password / Bitwarden:
--      select decrypted_secret from vault.decrypted_secrets where name='beep_vendor_credentials_key';
--
-- 4. Smoke test as the studio owner (replace <vendor-uuid> with a real id):
--      select set_vendor_credentials('<vendor-uuid>', 'testuser', 'testpass!', 'ACCT-123');
--      select * from get_vendor_credentials('<vendor-uuid>');
--      select clear_vendor_credentials('<vendor-uuid>');
--
-- 5. Audit log populates (owners only):
--      select * from vendor_credential_access_log order by occurred_at desc limit 5;
