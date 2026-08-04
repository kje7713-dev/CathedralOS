-- =============================================================================
-- CathedralOS — Novel-building: schema foundation (Phase 0/1, PR #1)
-- Migration: 20260804210000_add_novel_building_schema.sql
--
-- First deliverable toward novel-building capability (see docs/novel-building.md).
-- Phase 0/1 ships the data model + UI for outline-based generation. This
-- migration introduces the schema only; the iOS UI ships in a follow-up PR.
-- Sync (project_snapshots round-trip) is also a follow-up PR.
--
-- Adds:
--   5 tables: story_arc_templates, story_arcs, story_arc_beats,
--             outlines, outline_sections
--   3 seeded story arc templates (Three-Act, Hero's Journey, Mystery)
--   RLS, indexes, updated_at triggers
--
-- No existing tables are modified. No data is migrated. No LLM cost.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. updated_at trigger helper (idempotent; matches initial_schema.sql)
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. story_arc_templates (global reference data, not user-owned)
-- ---------------------------------------------------------------------------

create table if not exists public.story_arc_templates (
  id          uuid        primary key default gen_random_uuid(),
  name        text        not null unique,
  description text        not null default '',
  beats       jsonb       not null default '[]'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint story_arc_templates_beats_is_array
    check (jsonb_typeof(beats) = 'array')
);

create trigger story_arc_templates_set_updated_at
  before update on public.story_arc_templates
  for each row execute function public.set_updated_at();

alter table public.story_arc_templates enable row level security;

-- Read-only for users. Templates are seeded via migration only; new templates
-- land as a new migration so the catalog is versioned (see docs/novel-building.md).
create policy "story_arc_templates: authenticated can read"
  on public.story_arc_templates for select
  to authenticated
  using (true);

-- ---------------------------------------------------------------------------
-- 3. story_arcs (per-project, user-owned)
-- ---------------------------------------------------------------------------

create table if not exists public.story_arcs (
  id               uuid        primary key default gen_random_uuid(),
  user_id          uuid        not null references auth.users(id) on delete cascade,
  local_project_id text        not null,
  lineage_id       uuid        not null,
  template_id      uuid        references public.story_arc_templates(id) on delete set null,
  customizations   jsonb       not null default '{}'::jsonb,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint story_arcs_local_project_id_nonempty
    check (length(local_project_id) > 0),
  constraint story_arcs_customizations_is_object
    check (jsonb_typeof(customizations) = 'object')
);

create trigger story_arcs_set_updated_at
  before update on public.story_arcs
  for each row execute function public.set_updated_at();

create index if not exists idx_story_arcs_user_lineage
  on public.story_arcs (user_id, lineage_id);

create index if not exists idx_story_arcs_user_local_project
  on public.story_arcs (user_id, local_project_id);

create index if not exists idx_story_arcs_template
  on public.story_arcs (template_id);

alter table public.story_arcs enable row level security;

create policy "story_arcs: users can select own rows"
  on public.story_arcs for select
  using (auth.uid() = user_id);

create policy "story_arcs: users can insert own rows"
  on public.story_arcs for insert
  with check (auth.uid() = user_id);

create policy "story_arcs: users can update own rows"
  on public.story_arcs for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "story_arcs: users can delete own rows"
  on public.story_arcs for delete
  using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 4. story_arc_beats (per story_arc, ordered)
-- ---------------------------------------------------------------------------

create table if not exists public.story_arc_beats (
  id           uuid        primary key default gen_random_uuid(),
  story_arc_id uuid        not null references public.story_arcs(id) on delete cascade,
  position     integer     not null,
  role         text        not null default '',
  label        text        not null,
  details      text        not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint story_arc_beats_position_nonneg
    check (position >= 0),
  constraint story_arc_beats_label_nonempty
    check (length(label) > 0)
);

create trigger story_arc_beats_set_updated_at
  before update on public.story_arc_beats
  for each row execute function public.set_updated_at();

create index if not exists idx_story_arc_beats_arc_position
  on public.story_arc_beats (story_arc_id, position);

alter table public.story_arc_beats enable row level security;

-- RLS via parent (story_arcs has its own RLS).
create policy "story_arc_beats: users can select beats of own arcs"
  on public.story_arc_beats for select
  using (exists (
    select 1 from public.story_arcs a
    where a.id = story_arc_beats.story_arc_id
      and a.user_id = auth.uid()
  ));

create policy "story_arc_beats: users can insert beats to own arcs"
  on public.story_arc_beats for insert
  with check (exists (
    select 1 from public.story_arcs a
    where a.id = story_arc_beats.story_arc_id
      and a.user_id = auth.uid()
  ));

create policy "story_arc_beats: users can update beats of own arcs"
  on public.story_arc_beats for update
  using (exists (
    select 1 from public.story_arcs a
    where a.id = story_arc_beats.story_arc_id
      and a.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.story_arcs a
    where a.id = story_arc_beats.story_arc_id
      and a.user_id = auth.uid()
  ));

create policy "story_arc_beats: users can delete beats of own arcs"
  on public.story_arc_beats for delete
  using (exists (
    select 1 from public.story_arcs a
    where a.id = story_arc_beats.story_arc_id
      and a.user_id = auth.uid()
  ));

-- ---------------------------------------------------------------------------
-- 5. outlines (per-project, user-owned)
-- ---------------------------------------------------------------------------

create table if not exists public.outlines (
  id               uuid        primary key default gen_random_uuid(),
  user_id          uuid        not null references auth.users(id) on delete cascade,
  local_project_id text        not null,
  lineage_id       uuid        not null,
  story_arc_id     uuid        references public.story_arcs(id) on delete set null,
  name             text        not null default 'Outline',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint outlines_local_project_id_nonempty
    check (length(local_project_id) > 0)
);

create trigger outlines_set_updated_at
  before update on public.outlines
  for each row execute function public.set_updated_at();

create index if not exists idx_outlines_user_lineage
  on public.outlines (user_id, lineage_id);

create index if not exists idx_outlines_user_local_project
  on public.outlines (user_id, local_project_id);

create index if not exists idx_outlines_story_arc
  on public.outlines (story_arc_id);

alter table public.outlines enable row level security;

create policy "outlines: users can select own rows"
  on public.outlines for select
  using (auth.uid() = user_id);

create policy "outlines: users can insert own rows"
  on public.outlines for insert
  with check (auth.uid() = user_id);

create policy "outlines: users can update own rows"
  on public.outlines for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "outlines: users can delete own rows"
  on public.outlines for delete
  using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 6. outline_sections (per outline, supports nested grouping via parent_id)
-- ---------------------------------------------------------------------------

create table if not exists public.outline_sections (
  id            uuid        primary key default gen_random_uuid(),
  outline_id    uuid        not null references public.outlines(id) on delete cascade,
  parent_id     uuid        references public.outline_sections(id) on delete cascade,
  position      integer     not null,
  title         text        not null default '',
  summary       text        not null default '',
  container     text,
  pov           text,
  terminal_beat text,
  status        text        not null default 'draft',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint outline_sections_position_nonneg
    check (position >= 0),
  constraint outline_sections_container_valid
    check (
      container is null
      or container in (
        'modelDecides', 'beat', 'moment', 'vignette', 'microScene',
        'scene', 'developedScene', 'setPiece', 'sceneSequence',
        'shortStory', 'chapter', 'episode', 'novella'
      )
    ),
  constraint outline_sections_pov_valid
    check (
      pov is null
      or pov in (
        'firstPerson', 'secondPerson', 'thirdPersonLimited', 'thirdPersonOmniscient'
      )
    ),
  constraint outline_sections_status_valid
    check (status in ('draft', 'queued', 'generated', 'accepted'))
);

create trigger outline_sections_set_updated_at
  before update on public.outline_sections
  for each row execute function public.set_updated_at();

create index if not exists idx_outline_sections_outline_position
  on public.outline_sections (outline_id, position);

create index if not exists idx_outline_sections_parent
  on public.outline_sections (parent_id);

alter table public.outline_sections enable row level security;

-- RLS via parent (outlines has its own RLS).
create policy "outline_sections: users can select sections of own outlines"
  on public.outline_sections for select
  using (exists (
    select 1 from public.outlines o
    where o.id = outline_sections.outline_id
      and o.user_id = auth.uid()
  ));

create policy "outline_sections: users can insert sections to own outlines"
  on public.outline_sections for insert
  with check (exists (
    select 1 from public.outlines o
    where o.id = outline_sections.outline_id
      and o.user_id = auth.uid()
  ));

create policy "outline_sections: users can update sections of own outlines"
  on public.outline_sections for update
  using (exists (
    select 1 from public.outlines o
    where o.id = outline_sections.outline_id
      and o.user_id = auth.uid()
  ))
  with check (exists (
    select 1 from public.outlines o
    where o.id = outline_sections.outline_id
      and o.user_id = auth.uid()
  ));

create policy "outline_sections: users can delete sections of own outlines"
  on public.outline_sections for delete
  using (exists (
    select 1 from public.outlines o
    where o.id = outline_sections.outline_id
      and o.user_id = auth.uid()
  ));

-- ---------------------------------------------------------------------------
-- 7. Seed 3 starter story arc templates
-- ---------------------------------------------------------------------------

insert into public.story_arc_templates (id, name, description, beats) values
  (
    'a0000001-0000-0000-0000-000000000001',
    'Three-Act',
    'Classical three-act structure: setup, confrontation, resolution. Universal across most fiction genres.',
    $$[
      {"role": "setup", "label": "Setup", "description": "Introduce the world, characters, and the ordinary life that will be disrupted."},
      {"role": "inciting_incident", "label": "Inciting Incident", "description": "The event that disrupts the ordinary world and sets the story in motion."},
      {"role": "first_plot_point", "label": "First Plot Point", "description": "The protagonist commits to the central conflict and the story tilts into Act II."},
      {"role": "rising_action", "label": "Rising Action", "description": "Escalating complications, subplots, and stakes as the protagonist pursues the goal."},
      {"role": "midpoint", "label": "Midpoint", "description": "A reversal or revelation that doubles the stakes and reframes the conflict."},
      {"role": "crisis", "label": "Crisis", "description": "The lowest point — what looks like defeat, the dark night of the soul."},
      {"role": "climax", "label": "Climax", "description": "The decisive confrontation where the protagonist's arc turns."},
      {"role": "resolution", "label": "Resolution", "description": "The new normal. Loose threads are tied. The world has changed."}
    ]$$::jsonb
  ),
  (
    'a0000001-0000-0000-0000-000000000002',
    $$Hero's Journey$$,
    $$Joseph Campbell's monomyth: separation, initiation, return. Best for hero-driven adventure and coming-of-age stories.$$,
    $$[
      {"role": "ordinary_world", "label": "Ordinary World", "description": "The hero's normal life before the adventure begins."},
      {"role": "call_to_adventure", "label": "Call to Adventure", "description": "The hero is presented with a problem, challenge, or opportunity."},
      {"role": "refusal_of_call", "label": "Refusal of the Call", "description": "The hero hesitates or refuses the adventure, fearing the unknown."},
      {"role": "meeting_mentor", "label": "Meeting the Mentor", "description": "The hero meets a guide who gives advice, training, or confidence."},
      {"role": "crossing_threshold", "label": "Crossing the Threshold", "description": "The hero commits to the adventure and enters the special world."},
      {"role": "tests_allies_enemies", "label": "Tests, Allies, Enemies", "description": "The hero faces trials, makes friends, and identifies antagonists."},
      {"role": "approach_inmost_cave", "label": "Approach to the Inmost Cave", "description": "The hero nears the central ordeal, often facing a major fear."},
      {"role": "ordeal", "label": "Ordeal", "description": "The hero's greatest test — a life-or-death moment of transformation."},
      {"role": "reward", "label": "Reward", "description": "The hero claims something of value after surviving the ordeal."},
      {"role": "road_back", "label": "The Road Back", "description": "The hero begins the return journey, often with new stakes."},
      {"role": "resurrection", "label": "Resurrection", "description": "A final climactic test where the hero is transformed."},
      {"role": "return_with_elixir", "label": "Return with the Elixir", "description": "The hero returns to the ordinary world, changed, with something to share."}
    ]$$::jsonb
  ),
  (
    'a0000001-0000-0000-0000-000000000003',
    'Mystery',
    'Crime-driven structure: hook, investigation, false leads, reveal. Engineered for detective stories, thrillers, and puzzles.',
    $$[
      {"role": "the_crime", "label": "The Crime / Hook", "description": "Establish the crime, mystery, or question that drives the story."},
      {"role": "investigation_begins", "label": "Investigation Begins", "description": "The detective/protagonist takes the case and starts gathering evidence."},
      {"role": "first_suspect", "label": "First Suspect / Red Herring", "description": "An early suspect appears strong but is misdirection."},
      {"role": "rising_tension", "label": "Rising Tension", "description": "Stakes escalate, more clues surface, complications mount."},
      {"role": "key_revelation", "label": "Key Witness / Revelation", "description": "A pivotal clue reshapes the investigation."},
      {"role": "false_solution", "label": "False Solution", "description": "The protagonist (or reader) is led to a wrong conclusion."},
      {"role": "real_clue", "label": "Real Clue Surfaces", "description": "The actual culprit or truth becomes visible."},
      {"role": "confrontation", "label": "Confrontation", "description": "The protagonist confronts the antagonist with the truth."},
      {"role": "resolution", "label": "Resolution / Reveal", "description": "The case is closed and the world has changed."}
    ]$$::jsonb
  )
on conflict (id) do update set
  name        = excluded.name,
  description = excluded.description,
  beats       = excluded.beats,
  updated_at  = now();
