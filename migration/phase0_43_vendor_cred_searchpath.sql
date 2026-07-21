-- Fix: "function pgp_sym_decrypt(bytea, text) does not exist" when loading
-- (or saving) vendor credentials.
--
-- The vendor-credential RPCs were defined with
--   set search_path = public, vault, pg_temp
-- which omits `extensions`. Supabase installs pgcrypto into the `extensions`
-- schema, so the unqualified pgp_sym_encrypt / pgp_sym_decrypt calls can't be
-- resolved at plan time and the function errors out. Add `extensions` to their
-- search_path. Idempotent.

create extension if not exists pgcrypto with schema extensions;

alter function public.get_vendor_credentials(uuid)
  set search_path = public, vault, extensions, pg_temp;
alter function public.set_vendor_credentials(uuid, text, text, text)
  set search_path = public, vault, extensions, pg_temp;
