-- =============================================================================
-- Phase 3 of novel-building per docs/novel-building.md: pgvector + acceptance
-- indexing.
--
-- Enables the pgvector extension, creates the section_embeddings table that
-- stores per-section embeddings + extracted summaries, indexes for similarity
-- search, and an RPC function for retrieving similar accepted sections.
--
-- Embedding model: OpenAI text-embedding-3-small (1536 dim).
-- Storage strategy: keep BOTH extracted_summary (LLM-generated ~200-500 token
-- distillation used as the embed input) and raw_text (full section prose) so
-- we can re-embed cheaply if the model changes.
--
-- Index strategy: HNSW (write-heavy workload per spec).
-- Similarity: cosine distance via <=> operator.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Enable pgvector
-- ---------------------------------------------------------------------------

create extension if not exists vector;

-- ---------------------------------------------------------------------------
-- 2. section_embeddings table
-- ---------------------------------------------------------------------------

create table if not exists public.section_embeddings (
  id                 uuid        primary key default gen_random_uuid(),
  -- FK to public.projects(id) added in follow-up migration (see deployment log: original FK failed because public.projects not visible in deploy target DB)
  project_id         uuid        not null,
  -- FK to public.outline_sections(id) added in follow-up migration
  outline_section_id uuid        not null,

  -- The 1536-dim embedding (text-embedding-3-small)
  embedding          vector(1536) not null,

  -- LLM-generated distillation used as the embed input. ~200-500 tokens.
  -- Stored separately so we can re-embed if the model changes without
  -- re-running the extraction pass.
  extracted_summary  text        not null,

  -- The original full prose. Used for debugging + future re-extraction.
  raw_text           text        not null,

  -- Snapshot of section metadata at embed time (for retrieval display).
  container          text,
  pov                text,

  created_at         timestamptz not null default now(),

  constraint section_embeddings_outline_section_unique
    unique (outline_section_id)
);

-- ---------------------------------------------------------------------------
-- 3. Indexes
-- ---------------------------------------------------------------------------

-- HNSW for cosine distance (per Phase 3 spec — write-heavy workload)
create index if not exists idx_section_embeddings_embedding
  on public.section_embeddings
  using hnsw (embedding vector_cosine_ops);

-- Project-scoped queries (the most common access pattern)
create index if not exists idx_section_embeddings_project_created
  on public.section_embeddings (project_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 4. RLS
-- ---------------------------------------------------------------------------

alter table public.section_embeddings enable row level security;

-- Simplified RLS: any authenticated user can read embeddings.
-- Per-user scoping deferred. Would need to join through outline_sections →
-- outlines once we know which table tracks project ownership. The `projects`
-- table does not exist in CathedralOS — projects are tracked via
-- project_snapshots (lineage_id, identity_key) and name strings on
-- generation_outputs. Revisit when a proper projects model exists.
create policy "section_embeddings: any authenticated can select"
  on public.section_embeddings for select
  using (auth.role() = 'authenticated');

-- Inserts/updates/deletes: service-role only (the embed-section edge function
-- uses the service role to write). No policies for the authenticated role.

-- ---------------------------------------------------------------------------
-- 5. Similarity search RPC
-- ---------------------------------------------------------------------------

create or replace function public.find_similar_sections(
  query_embedding  vector(1536),
  query_project_id uuid,
  match_threshold  float  default 0.7,
  match_count      int    default 5
)
returns table (
  outline_section_id uuid,
  extracted_summary  text,
  similarity         float
)
language sql stable
as $$
  select
    se.outline_section_id,
    se.extracted_summary,
    1 - (se.embedding <=> query_embedding) as similarity
  from public.section_embeddings se
  where se.project_id = query_project_id
    and 1 - (se.embedding <=> query_embedding) > match_threshold
  order by se.embedding <=> query_embedding
  asc
  limit match_count;
$$;

comment on function public.find_similar_sections(vector(1536), uuid, float, int) is
  'Find similar accepted sections within a project. Cosine similarity threshold + count.';
