-- Post-generation coherence warnings (PR-360-Y).
-- Persisted by generate-story's fire-and-forget post-gen coherence pass
-- against the new mode:"post-generation" capability of the coherence-check
-- edge function. Queried by iOS GenerationOutputDetailView to render the
-- soft-warn yellow card on the output detail screen.
--
-- Mirrors generation_outputs RLS pattern (users see only their own rows).
-- Only the service role (generate-story) inserts; no user-facing INSERT
-- policy needed (service role bypasses RLS).

CREATE TABLE IF NOT EXISTS public.generation_output_warnings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  generation_output_id uuid NOT NULL REFERENCES public.generation_outputs(id) ON DELETE CASCADE,
  warning_type text NOT NULL CHECK (warning_type IN (
    'character_state','continuity_fact','scene_ending_state','pov_drift',
    'plot_thread','premise_inversion','invented_character',
    'name_not_in_canon','output_vs_premise'
  )),
  severity text NOT NULL CHECK (severity IN ('warn','high')),
  message text NOT NULL,
  conflicting_section_ids uuid[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_generation_output_warnings_output
  ON public.generation_output_warnings (generation_output_id);

ALTER TABLE public.generation_output_warnings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "generation_output_warnings: users can select own rows"
  ON public.generation_output_warnings FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.generation_outputs go
      WHERE go.id = generation_output_warnings.generation_output_id
        AND go.user_id = auth.uid()
    )
  );
