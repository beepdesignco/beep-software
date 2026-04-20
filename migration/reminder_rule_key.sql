-- Auto-reminder cron dedup key.
-- Every auto-send writes a rule_key like 'due', 'before-3', 'after-10' so the
-- cron can tell which rules have already fired for a given invoice.
-- Manual reminders (or invoice sends) leave rule_key null.

alter table invoice_sends add column if not exists rule_key text;

-- Partial unique index: a given (invoice_id, rule_key) can only fire once.
-- Null rule_keys (manual sends) aren't constrained.
create unique index if not exists uq_invoice_sends_rule
  on invoice_sends(invoice_id, rule_key)
  where rule_key is not null;
