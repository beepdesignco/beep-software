-- phase0_63 — notifications.dismissed_at (WORKLIST §3.5.2c)
-- Clearing a notification from the queue must never destroy it: dismissed_at
-- (distinct from read_at) hides it from the active bell/queue while the
-- full history stays queryable in the All-notifications backlog view.
-- Rollback: alter table notifications drop column dismissed_at;

alter table notifications add column if not exists dismissed_at timestamptz;

select column_name from information_schema.columns
  where table_name = 'notifications' and column_name = 'dismissed_at';
