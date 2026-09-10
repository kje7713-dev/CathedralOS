-- Story planning contract fields are nullable for legacy outlines.
alter table public.outline_sections
  add column if not exists entry_state text,
  add column if not exists dramatic_event text,
  add column if not exists resulting_change text,
  add column if not exists terminal_state text;

comment on column public.outline_sections.entry_state is 'State inherited at section entry.';
comment on column public.outline_sections.dramatic_event is 'Concrete event/objective required by the section contract.';
comment on column public.outline_sections.resulting_change is 'Material change required before the section ends.';
comment on column public.outline_sections.terminal_state is 'State handed to the next section.';
