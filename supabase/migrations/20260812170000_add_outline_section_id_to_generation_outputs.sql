-- Migration: 20260812170000_add_outline_section_id_to_generation_outputs.sql
--
-- Background
-- ----------
-- PR #325 + PR #326 wired the iOS side to display section <-> output links via
-- `GenerationOutput.outlineSectionID`, but the cloud `generation_outputs`
-- table never had a corresponding `outline_section_id` column. Every
-- generation row came back with the field absent on the cloud record, the
-- iOS DTO decoded it as nil, the @Query filter `$0.outlineSectionID != nil`
-- excluded every output, the eye button never rendered, and the From-Section
-- pill in the detail view had nothing to resolve.
--
-- This migration adds the column. Existing rows stay NULL (no derivation
-- path back to a specific section), but new generations routed through
-- `run-outline -> generate-story` will write `outline_section_id`
-- from the chapter_run's section id (PR #327 — backend fix-forward).
--
-- Intentionally no FK to outline_sections in this migration: the link is
-- informational and iOS handles a missing link gracefully. A FK can be
-- added in a follow-up migration once the data shape is verified.

alter table public.generation_outputs
  add column if not exists outline_section_id uuid;

create index if not exists idx_generation_outputs_outline_section_id
  on public.generation_outputs (outline_section_id)
  where outline_section_id is not null;
