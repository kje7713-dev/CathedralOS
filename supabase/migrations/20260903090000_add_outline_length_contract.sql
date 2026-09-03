-- PR 2: persist the book-level and section-level length contract.
-- These are planning targets, not provider completion ceilings.

ALTER TABLE public.outlines
  ADD COLUMN IF NOT EXISTS planning_format text,
  ADD COLUMN IF NOT EXISTS target_word_count integer,
  ADD COLUMN IF NOT EXISTS target_word_count_min integer,
  ADD COLUMN IF NOT EXISTS target_word_count_max integer,
  ADD COLUMN IF NOT EXISTS projected_word_count integer;

ALTER TABLE public.outline_sections
  ADD COLUMN IF NOT EXISTS target_words integer,
  ADD COLUMN IF NOT EXISTS target_words_min integer,
  ADD COLUMN IF NOT EXISTS target_words_max integer;

ALTER TABLE public.outlines
  ADD CONSTRAINT outlines_length_contract_valid
  CHECK (
    (planning_format IS NULL AND target_word_count IS NULL AND target_word_count_min IS NULL
      AND target_word_count_max IS NULL AND projected_word_count IS NULL)
    OR (
      planning_format IS NOT NULL
      AND target_word_count IS NOT NULL AND target_word_count > 0
      AND target_word_count_min IS NOT NULL AND target_word_count_min > 0
      AND target_word_count_max IS NOT NULL AND target_word_count_max >= target_word_count_min
      AND projected_word_count IS NOT NULL AND projected_word_count >= 0
    )
  );

ALTER TABLE public.outline_sections
  ADD CONSTRAINT outline_sections_length_contract_valid
  CHECK (
    (target_words IS NULL AND target_words_min IS NULL AND target_words_max IS NULL)
    OR (
      target_words IS NOT NULL AND target_words > 0
      AND target_words_min IS NOT NULL AND target_words_min > 0
      AND target_words_max IS NOT NULL AND target_words_max >= target_words_min
    )
  );

COMMENT ON COLUMN public.outlines.planning_format IS
  'Book-level planning format, such as novel; planning only, not a provider ceiling.';
COMMENT ON COLUMN public.outlines.target_word_count IS
  'Book-level intended word count for planning and telemetry.';
COMMENT ON COLUMN public.outlines.projected_word_count IS
  'Sum of section planning midpoints at contract creation time.';
COMMENT ON COLUMN public.outline_sections.target_words IS
  'Section planning midpoint; container still owns the generation output cap.';
