-- phase0_62 — Order groups (WORKLIST §6D.4)
-- Internal annotation linking multiple proposal items/components that are
-- really ONE vendor order (same fabric on sofa + curtains; same wallpaper
-- in two rooms). Pure annotation layer: no effect on proposal structure,
-- pricing, or client documents. Members are a jsonb array
--   [{itemId, compId|null, note}]
-- (note = e.g. "20 yd → curtain workroom"). Untag per member; substitution
-- on a member just drops it from the group.
-- Member-scoped RLS like project_meetings.
-- Rollback: drop table order_groups;

begin;

create table if not exists order_groups (
  id uuid primary key,
  studio_id uuid not null references studios(id) on delete cascade,
  project_id uuid not null references projects(id) on delete cascade,
  name text not null,
  vendor_id uuid references vendors(id) on delete set null,
  note text,
  members jsonb not null default '[]'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists order_groups_project_idx on order_groups(project_id) where deleted_at is null;

alter table order_groups enable row level security;

drop policy if exists order_groups_all on order_groups;
create policy order_groups_all on order_groups
  for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'order_groups_set_updated_at') then
    create trigger order_groups_set_updated_at before update on order_groups
      for each row execute function set_updated_at();
  end if;
end $$;

commit;

select tablename from pg_tables where tablename = 'order_groups';
