-- Phase F: add receipt jsonb column to expenses so the full file record
-- (name/size/type/storagePath/uploadedAt) survives sync.
-- receipt_path text column stays for backward compat; dropped when unused.

alter table expenses add column if not exists receipt jsonb;

-- Also: projects were missing a files column. Add one for sync.
alter table projects add column if not exists files jsonb not null default '[]'::jsonb;
