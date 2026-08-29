-- Outline planning and suggestion LLM calls are billable material work.
alter table public.generation_usage_events
  drop constraint if exists generation_usage_events_purpose_check;
alter table public.generation_usage_events
  add constraint generation_usage_events_purpose_check
  check (purpose in ('generate', 'coherence-check', 'ai-cover', 'outline-suggestion'));
