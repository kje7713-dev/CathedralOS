-- Repair scene-memory identity references that were stored at character scope
-- (for example "Dr. Sela Aro") instead of attribute scope
-- (for example "character:dr-sela-aro:identity:pronouns").
--
-- The runtime now canonicalizes these references server-side. This forward
-- migration cleans existing rows so Project State and future extraction see the
-- same canonical identities immediately.
--
-- Also widen llm_prompts.call_type to the two audit values already emitted by
-- section-embedding.ts. The old constraint silently rejected those best-effort
-- audit inserts in production.

alter table public.llm_prompts
  drop constraint if exists llm_prompts_call_type_check;

alter table public.llm_prompts
  add constraint llm_prompts_call_type_check
  check (
    call_type in (
      'generate-story',
      'coherence-check',
      'embed-section',
      'embed-section-extract',
      'embed-section-vectorize',
      'rag-pull'
    )
  );

with fact_rows as (
  select
    se.id,
    fact.ordinality,
    fact.value,
    regexp_match(
      coalesce(fact.value ->> 'fact', ''),
      '^character:([^:]+):identity:([^:]+):',
      'i'
    ) as parts
  from public.section_embeddings se
  cross join lateral jsonb_array_elements(se.continuity_facts)
    with ordinality as fact(value, ordinality)
),
normalized as (
  select
    id,
    ordinality,
    value,
    case
      when parts is null then null
      else format(
        'character:%s:identity:%s',
        trim(
          both '-' from regexp_replace(
            lower(parts[1]),
            '[^a-z0-9]+',
            '-',
            'g'
          )
        ),
        trim(
          both '-' from regexp_replace(
            lower(parts[2]),
            '[^a-z0-9]+',
            '-',
            'g'
          )
        )
      )
    end as canonical_reference
  from fact_rows
),
rewritten as (
  select
    id,
    jsonb_agg(
      case
        when canonical_reference is null then value
        else
          case
            when value ->> 'prior_fact_reference' = value ->> 'reference'
              then jsonb_set(
                jsonb_set(
                  value,
                  '{reference}',
                  to_jsonb(canonical_reference),
                  true
                ),
                '{prior_fact_reference}',
                to_jsonb(canonical_reference),
                true
              )
            else jsonb_set(
              value,
              '{reference}',
              to_jsonb(canonical_reference),
              true
            )
          end
      end
      order by ordinality
    ) as continuity_facts
  from normalized
  group by id
)
update public.section_embeddings se
set continuity_facts = rewritten.continuity_facts
from rewritten
where se.id = rewritten.id
  and se.continuity_facts is distinct from rewritten.continuity_facts;
