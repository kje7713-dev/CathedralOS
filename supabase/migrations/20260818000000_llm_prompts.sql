-- LLM prompt storage for debugging, audit, and UI display.
-- One row per LLM call. Stores the full prompt + response + token counts.
-- Referenced by output_id (nullable), outline_section_id (nullable), project_id (nullable).
-- Used by Track 1 (storage) of the prompt + RAG redesign.

CREATE TABLE IF NOT EXISTS public.llm_prompts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  call_type text NOT NULL CHECK (call_type IN ('generate-story','coherence-check','embed-section','rag-pull')),
  output_id uuid REFERENCES public.generation_outputs(id),
  outline_section_id uuid REFERENCES public.outline_sections(id),
  project_id uuid REFERENCES public.projects(id),
  model text NOT NULL,
  prompt text NOT NULL,
  response text,
  prompt_tokens integer,
  completion_tokens integer,
  total_tokens integer,
  duration_ms integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_llm_prompts_output ON public.llm_prompts(output_id);
CREATE INDEX IF NOT EXISTS idx_llm_prompts_project ON public.llm_prompts(project_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_llm_prompts_section ON public.llm_prompts(outline_section_id);
