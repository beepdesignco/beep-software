-- Phase 0, step 8 — pgvector extension + embeddings table (scaffold).
--
-- Purpose: get the vector infrastructure in place now so Feature 14 (semantic
-- search) lands without a schema migration at feature-build time. The table
-- is created empty; population happens only when Feature 14 ships its
-- embedding pipeline (Voyage AI).
--
-- Design decisions:
--   • Polymorphic (entity_type + entity_id + chunk_index) so one table can
--     hold embeddings for items, POs, activity entries, documents, notes,
--     emails, specs, tear sheets, etc. Same pattern as activity_entries.
--   • `chunk_index` supports long texts split into multiple embeddings;
--     uniqueness on (entity_type, entity_id, chunk_index) prevents dup
--     inserts.
--   • `content_hash` lets the embedding pipeline skip re-embedding unchanged
--     text (cheap cache check before hitting Voyage).
--   • `content_text` is stored so search results can display a snippet
--     without re-fetching the source entity.
--   • `model` records which Voyage model produced this embedding; lets us
--     run multiple models side-by-side during A/B or migrate models
--     without re-embedding everything at once.
--   • `vector(1024)` dimension matches Voyage's `voyage-3` default. If we
--     end up picking a model with different dims, alter-type is fine on
--     an empty table.
--   • HNSW index for cosine similarity — partial index on WHERE embedding
--     IS NOT NULL so the empty scaffolded state doesn't matter.
--
-- RLS: is_studio_member for basic scoping. Feature 14's query layer will
-- add per-entity permission filtering (e.g. hide invoice hits from members
-- without view_financials).
--
-- Idempotent: safe to re-run.

begin;

-- ════════════════════════════════════════════════════════════════
-- EXTENSION
-- ════════════════════════════════════════════════════════════════

create extension if not exists vector;

-- ════════════════════════════════════════════════════════════════
-- EMBEDDINGS
-- ════════════════════════════════════════════════════════════════

create table if not exists embeddings (
  id                  uuid primary key default gen_random_uuid(),
  studio_id           uuid not null references studios(id) on delete cascade,
  entity_type         text not null,                          -- 'proposal_item' | 'purchase_order' | 'activity_entry' | ...
  entity_id           uuid not null,
  chunk_index         integer not null default 0,             -- 0 for whole-entity embedding; >0 for split chunks
  content_hash        text not null,                          -- dedup / skip-unchanged check
  content_text        text not null,                          -- the actual text embedded (for snippet display)
  embedding           vector(1024),                           -- null until populated
  model               text,                                   -- 'voyage-3' etc.
  metadata            jsonb not null default '{}'::jsonb,     -- free-form filter context (vendor_id, price, project_id, tags, ...)
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  unique (entity_type, entity_id, chunk_index)
);

create index if not exists idx_embeddings_studio
  on embeddings(studio_id);

create index if not exists idx_embeddings_entity
  on embeddings(entity_type, entity_id);

-- Vector index for cosine-similarity nearest-neighbor queries. Partial so
-- the index is valid even while the scaffolded table is empty / null.
create index if not exists idx_embeddings_vector
  on embeddings using hnsw (embedding vector_cosine_ops)
  with (m = 16, ef_construction = 64)
  where embedding is not null;

-- ════════════════════════════════════════════════════════════════
-- RLS
-- ════════════════════════════════════════════════════════════════

alter table embeddings enable row level security;

drop policy if exists embeddings_select on embeddings;
drop policy if exists embeddings_modify on embeddings;

-- SELECT: any studio member. Feature 14's query layer adds per-entity
-- permission filtering on top (e.g. hiding financial rows).
create policy embeddings_select on embeddings for select
  using (is_studio_member(studio_id));

-- INSERT/UPDATE/DELETE: any studio member. The embedding pipeline will
-- typically run as service_role (which bypasses RLS) but this policy
-- keeps the door open for manual adjustments.
create policy embeddings_modify on embeddings for all
  using (is_studio_member(studio_id))
  with check (is_studio_member(studio_id));

-- updated_at trigger
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'embeddings_set_updated_at') then
    create trigger embeddings_set_updated_at before update on embeddings
      for each row execute function set_updated_at();
  end if;
end $$;

commit;

-- ════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- ════════════════════════════════════════════════════════════════

-- 1. Extension enabled (expect 1 row).
select extname, extversion from pg_extension where extname = 'vector';

-- 2. Table exists (expect 1 row).
select table_name from information_schema.tables
  where table_schema = 'public' and table_name = 'embeddings';

-- 3. Columns landed with expected types.
select column_name, data_type, udt_name, is_nullable, column_default
  from information_schema.columns
  where table_name = 'embeddings'
  order by ordinal_position;

-- 4. RLS policies (expect 2 rows: embeddings_select + embeddings_modify).
select policyname, cmd from pg_policies
  where tablename = 'embeddings' order by policyname;

-- 5. Indexes (expect 4: pk, uq_entity_chunk, idx_embeddings_studio, idx_embeddings_entity, idx_embeddings_vector).
select indexname, tablename from pg_indexes
  where tablename = 'embeddings' order by indexname;
