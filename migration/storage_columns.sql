-- Phase F: add receipt jsonb column to expenses so the full file record
-- (name/size/type/storagePath/uploadedAt) survives sync.
-- receipt_path text column stays for backward compat; dropped when unused.

alter table expenses add column if not exists receipt jsonb;
