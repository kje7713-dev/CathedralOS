-- =============================================================================
-- CathedralOS — Repair audit on outline_suggestion_runs
-- Migration: 20260912120000_outline_suggestion_run_repair_audit.sql
--
-- PR6 of Fix the Shit arc: tracks when a persisted suggestion run has been
-- repaired from a fresh canonical recipe so the recovery path can be audited
-- and surfaced to the device.
-- =============================================================================

alter table public.outline_suggestion_runs
  add column if not exists repaired_at timestamptz,
  add column if not exists repaired_from_recipe_hash text;

create index if not exists idx_outline_suggestion_runs_repaired
  on public.outline_suggestion_runs (user_id, repaired_at desc)
  where repaired_at is not null;

comment on column public.outline_suggestion_runs.repaired_at is
  'When the persisted story_material was repaired from the live canonical recipe (PR6 of Fix the Shit).';
comment on column public.outline_suggestion_runs.repaired_from_recipe_hash is
  'SHA-256 of the canonical recipe used to repair the story_material; lets the device surface provenance.';
