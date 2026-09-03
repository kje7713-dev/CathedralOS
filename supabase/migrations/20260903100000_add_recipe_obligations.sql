-- PR 3: preserve the recipe-obligation assignments made during planning.
-- IDs are auditable planning metadata; they do not create embeddings or charges.

ALTER TABLE public.outline_sections
  ADD COLUMN IF NOT EXISTS recipe_requirement_ids jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.outline_sections
  ADD CONSTRAINT outline_sections_recipe_requirement_ids_valid
  CHECK (jsonb_typeof(recipe_requirement_ids) = 'array');

COMMENT ON COLUMN public.outline_sections.recipe_requirement_ids IS
  'Recipe obligation IDs materially advanced by this section; planning metadata only.';
