-- Behavioral DB tests for the forward scene-memory stage ledger migration.
-- Run after migrations in a transaction, for example:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/database/scene_memory_stage_ledger.test.sql

create extension if not exists pgtap;
begin;
select plan(8);

insert into auth.users (id, aud, role, email)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'authenticated', 'authenticated',
        'scene-memory-stage-ledger@example.invalid');
insert into public.user_entitlements (user_id, monthly_credit_allowance, purchased_credit_balance)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 10, 0);
insert into public.generation_outputs (
  id, user_id, project_name, prompt_pack_name, title, output_text,
  source_payload_json, model_name, generation_action, generation_length_mode,
  output_budget, status, visibility, allow_remix
) values (
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'stage test', 'stage test', 'stage test',
  'persisted prose', '{}'::jsonb, 'gpt-4o-mini', 'generate', 'medium',
  100, 'complete', 'private', false
);

select results_eq(
  $$select settlement_status, remaining_credits
      from public.settle_scene_memory_stage(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb:scene-memory-extraction:v2',
        'v2', 'scene-memory-extraction',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,
        'gpt-4o-mini', 100, 20, 2, 1, 10, 9
      )$$,
  $$values ('settled'::text, 8::integer)$$,
  'first stage settlement debits once and records remaining credits'
);

select is(
  (select count(*) from public.generation_usage_events
    where stage_identity = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb:scene-memory-extraction:v2'),
  1::bigint,
  'versioned stage identity is unique'
);

select results_eq(
  $$select settlement_status, remaining_credits
      from public.settle_scene_memory_stage(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb:scene-memory-extraction:v2',
        'v2', 'scene-memory-extraction',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,
        'gpt-4o-mini', 100, 20, 2, 1, 10, 9
      )$$,
  $$values ('duplicate'::text, 8::integer)$$,
  'repeating the same stage is a no-op'
);

select throws_ok(
  $$select * from public.settle_scene_memory_stage(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb:scene-memory-extraction:v2',
    'v3', 'scene-memory-extraction',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,
    'gpt-4o-mini', 100, 20, 2, 1, 10, 9
  )$$,
  NULL,
  'stage version mismatch fails closed'
);

insert into public.generation_outputs (
  id, user_id, project_name, prompt_pack_name, title, output_text,
  source_payload_json, model_name, generation_action, generation_length_mode,
  output_budget, status, visibility, allow_remix
) values (
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'stage test', 'stage test', 'legacy',
  'legacy prose', '{}'::jsonb, 'gpt-4o-mini', 'generate', 'medium',
  100, 'complete', 'private', false
);
insert into public.generation_usage_events (
  user_id, generation_output_id, action, purpose, model_name,
  input_tokens, output_tokens, status, idempotency_key, credit_revenue_usd
) values (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'scene-memory-extraction',
  'embed-section', 'gpt-4o-mini', 100, 20, 'complete',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc:scene-memory-extraction', 0.10
);

select results_eq(
  $$select settlement_status
      from public.settle_scene_memory_stage(
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
        'cccccccc-cccc-4ccc-8ccc-cccccccccccc:scene-memory-extraction:v2',
        'v2', 'scene-memory-extraction',
        'cccccccc-cccc-4ccc-8ccc-cccccccccccc'::uuid,
        'gpt-4o-mini', 100, 20, 2
      )$$,
  $$values ('duplicate'::text)$$,
  'legacy extraction event is recognized without a second debit'
);

select is(
  (select monthly_credit_allowance + purchased_credit_balance
     from public.user_entitlements
    where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  8,
  'legacy compatibility lookup leaves the balance unchanged'
);

select is(
  (select count(*) from public.user_credit_ledger
    where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      and related_generation_output_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  1::bigint,
  'settlement writes exactly one credit ledger debit'
);

select * from finish();
rollback;
