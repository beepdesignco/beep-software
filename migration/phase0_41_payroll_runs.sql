-- Time + Payroll: payroll_runs — an immutable, owner-only ledger of finalized
-- pay periods. Each row snapshots a period's per-person gross (hours × pay
-- rate) at finalize time and records when it was paid, so payroll history is
-- preserved even as time entries change afterward.
--
-- Owner-only RLS (payroll is sensitive) — mirrors the time_entries owner scope.
-- Idempotent.

begin;

create table if not exists payroll_runs (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios(id) on delete cascade,
  period_start  date,
  period_end    date,
  label         text,
  breakdown     jsonb not null default '[]'::jsonb,   -- [{userId,name,hours,payRate,gross}]
  total_hours   numeric(12,2) not null default 0,
  total_gross   numeric(12,2) not null default 0,
  paid_at       date,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz
);

create index if not exists idx_payroll_runs_studio
  on payroll_runs(studio_id) where deleted_at is null;

alter table payroll_runs enable row level security;

drop policy if exists payroll_runs_all on payroll_runs;
create policy payroll_runs_all on payroll_runs for all
  using (is_studio_owner(studio_id))
  with check (is_studio_owner(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'payroll_runs_set_updated_at') then
    create trigger payroll_runs_set_updated_at before update on payroll_runs
      for each row execute function set_updated_at();
  end if;
end $$;

commit;
