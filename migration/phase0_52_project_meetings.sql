-- Project meeting notes: date/time-stamped meeting log per project.
-- Member-scoped RLS (any studio member can log/edit meetings).

begin;

create table if not exists project_meetings (
  id uuid primary key,
  studio_id uuid not null references studios(id) on delete cascade,
  project_id uuid not null references projects(id) on delete cascade,
  meeting_at timestamptz,
  title text,
  notes text,
  attendees text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists project_meetings_project_idx on project_meetings(project_id) where deleted_at is null;

alter table project_meetings enable row level security;

drop policy if exists project_meetings_all on project_meetings;
create policy project_meetings_all on project_meetings
  for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'project_meetings_set_updated_at') then
    create trigger project_meetings_set_updated_at before update on project_meetings
      for each row execute function set_updated_at();
  end if;
end $$;

commit;

select tablename from pg_tables where tablename = 'project_meetings';
