-- Paid back-cover synopsis generation uses the shared billable-LLM runner.
alter table public.generation_usage_events
  drop constraint if exists generation_usage_events_purpose_check;

alter table public.generation_usage_events
  add constraint generation_usage_events_purpose_check
  check (purpose in ('generate', 'coherence-check', 'ai-cover', 'outline-suggestion', 'embed-section', 'epub-synopsis'));
