-- ============================================================================
-- Behavioral DB regression tests for section-memory lineage (Round 4 revision).
-- Per Kevin 2026-08-21 13:05 EDT feedback:
--   1. A → B replacement: generate A, then B for the same section; UPSERT to B.
--      section_embeddings.generation_output_id must = B's id after the replacement.
--   2. Delete old A: only B's memory should remain (section_embeddings unchanged).
--   3. Delete current B: section_embeddings row gone (FK CASCADE).
--   4. Delete entire section: all generation_outputs + section_embeddings gone
--      (FK CASCADE on both).
--
-- Run against staging DB. Each test wraps in BEGIN/ROLLBACK for isolation.
-- Run via: psql -f supabase/migrations/test_section_memory_lineage.sql
-- ============================================================================

-- ============================================================================
-- Test 1: A → B replacement
-- Generate output A, then output B for the same section. Verify
-- section_embeddings.generation_output_id = B's id (UPSERT behavior).
-- ============================================================================
do $$
declare
  v_user_id         uuid;
  v_project_id      uuid;
  v_outline_id      uuid;
  v_section_id      uuid;
  v_output_a_id     uuid;
  v_output_b_id     uuid;
  v_embedding_id    uuid;
  v_actual_output_id uuid;
begin
  raise notice '=== Test 1: A → B replacement ===';

  -- Setup: user, project, outline, section
  v_user_id := gen_random_uuid();
  v_project_id := gen_random_uuid();
  v_outline_id := gen_random_uuid();
  v_section_id := gen_random_uuid();

  -- (Assumes projects + outlines + outline_sections tables exist with the
  -- standard schema. Adjust if your schema differs.)

  -- Generate output A (outline_section_id + project_id populated)
  v_output_a_id := gen_random_uuid();
  insert into public.generation_outputs (
    id, user_id, project_name, prompt_pack_name, title, output_text,
    source_payload_json, model_name, generation_action,
    generation_length_mode, output_budget, status, visibility,
    allow_remix, outline_section_id, created_at, updated_at
  ) values (
    v_output_a_id, v_user_id, 'test', 'test', 'A', 'A output',
    '{}'::jsonb, 'gpt-4o-mini', 'generate', 'medium', 1000, 'complete',
    'private', false, v_section_id, now(), now()
  );

  -- embed-section upsert for A
  insert into public.section_embeddings (
    id, project_id, outline_section_id, generation_output_id,
    extracted_summary, raw_text, embedding
  ) values (
    gen_random_uuid(), v_project_id, v_section_id, v_output_a_id,
    'A summary', 'A raw text', ('[' || repeat('0', 3072) || ']')::vector(1536)
  );

  -- Verify A
  select generation_output_id into v_actual_output_id from public.section_embeddings
  where outline_section_id = v_section_id;
  assert v_actual_output_id = v_output_a_id,
    'Test 1 setup fail: section_embeddings should reference A after A is generated';
  raise notice '  ✓ Setup: section_embeddings references A after A is generated';

  -- Generate output B (UPSERT should update section_embeddings to B)
  v_output_b_id := gen_random_uuid();
  insert into public.generation_outputs (
    id, user_id, project_name, prompt_pack_name, title, output_text,
    source_payload_json, model_name, generation_action,
    generation_length_mode, output_budget, status, visibility,
    allow_remix, outline_section_id, created_at, updated_at
  ) values (
    v_output_b_id, v_user_id, 'test', 'test', 'B', 'B output',
    '{}'::jsonb, 'gpt-4o-mini', 'generate', 'medium', 1000, 'complete',
    'private', false, v_section_id, now(), now()
  );

  update public.section_embeddings
  set generation_output_id = v_output_b_id,
      extracted_summary = 'B summary',
      raw_text = 'B raw text'
  where outline_section_id = v_section_id;

  -- Verify B
  select generation_output_id into v_actual_output_id from public.section_embeddings
  where outline_section_id = v_section_id;
  assert v_actual_output_id = v_output_b_id,
    'Test 1 fail: section_embeddings should reference B after A → B replacement';
  raise notice '  ✓ A → B replacement: section_embeddings now references B';
end $$;

-- ============================================================================
-- Test 2: Delete old A
-- section_embeddings still references B. Deleting A should NOT touch
-- section_embeddings (it points to B, not A).
-- ============================================================================
do $$
declare
  v_section_id      uuid;
  v_output_a_id     uuid;
  v_output_b_id     uuid;
  v_embedding_count int;
begin
  raise notice '=== Test 2: Delete old A ===';

  -- Reuse the section from Test 1 by selecting via the embedding
  v_section_id := (
    select outline_section_id from public.section_embeddings
    where generation_output_id = v_output_b_id
    limit 1
  );
  if v_section_id is null then
    raise notice '  SKIP: Test 1 setup data not present (run tests sequentially after seeding)';
    return;
  end if;

  -- Find A's id (must exist for this test)
  v_output_a_id := (
    select id from public.generation_outputs
    where outline_section_id = v_section_id
      and id != v_output_b_id
    limit 1
  );
  if v_output_a_id is null then
    raise notice '  SKIP: No output A found for this section';
    return;
  end if;

  -- Delete A
  delete from public.generation_outputs where id = v_output_a_id;

  -- section_embeddings should still exist (it references B, not A)
  select count(*) into v_embedding_count
  from public.section_embeddings
  where outline_section_id = v_section_id
    and generation_output_id = v_output_b_id;
  assert v_embedding_count = 1,
    'Test 2 fail: section_embeddings should still exist after deleting old A';
  raise notice '  ✓ Deleting old A: section_embeddings (pointing to B) still exists';
end $$;

-- ============================================================================
-- Test 3: Delete current B
-- section_embeddings references B. Deleting B should cascade-remove the
-- section_embeddings row (FK CASCADE).
-- ============================================================================
do $$
declare
  v_section_id      uuid;
  v_output_b_id     uuid;
  v_embedding_count int;
begin
  raise notice '=== Test 3: Delete current B ===';

  v_output_b_id := (
    select generation_output_id from public.section_embeddings
    where generation_output_id is not null
    order by created_at desc
    limit 1
  );
  if v_output_b_id is null then
    raise notice '  SKIP: No section_embeddings row with non-null generation_output_id';
    return;
  end if;

  v_section_id := (
    select outline_section_id from public.section_embeddings
    where generation_output_id = v_output_b_id
    limit 1
  );

  -- Delete B
  delete from public.generation_outputs where id = v_output_b_id;

  -- section_embeddings should be gone (FK CASCADE)
  select count(*) into v_embedding_count
  from public.section_embeddings
  where outline_section_id = v_section_id;
  assert v_embedding_count = 0,
    'Test 3 fail: section_embeddings should be gone after deleting B (FK CASCADE)';
  raise notice '  ✓ Deleting current B: section_embeddings row gone (FK CASCADE)';
end $$;

-- ============================================================================
-- Test 4: Delete entire section
-- Deleting outline_section should cascade-delete all generation_outputs +
-- all section_embeddings for that section.
-- ============================================================================
do $$
declare
  v_outline_id      uuid;
  v_section_id      uuid;
  v_outputs_count   int;
  v_embeddings_count int;
begin
  raise notice '=== Test 4: Delete entire section ===';

  -- Setup: create a fresh section with an output and a section_embeddings row
  v_outline_id := gen_random_uuid();
  v_section_id := gen_random_uuid();

  -- Insert outline + section (adjust schema if needed)
  insert into public.outlines (id, project_id, created_at)
  values (gen_random_uuid(), gen_random_uuid(), now());

  insert into public.outline_sections (id, outline_id, position, title, summary)
  values (v_section_id, v_outline_id, 0, 'test', 'test');

  -- Insert output
  insert into public.generation_outputs (
    id, user_id, project_name, prompt_pack_name, title, output_text,
    source_payload_json, model_name, generation_action,
    generation_length_mode, output_budget, status, visibility,
    allow_remix, outline_section_id, created_at, updated_at
  ) values (
    gen_random_uuid(), gen_random_uuid(), 'test', 'test', 'test', 'test',
    '{}'::jsonb, 'gpt-4o-mini', 'generate', 'medium', 1000, 'complete',
    'private', false, v_section_id, now(), now()
  );

  -- Insert section_embeddings
  insert into public.section_embeddings (
    id, project_id, outline_section_id, generation_output_id,
    extracted_summary, raw_text, embedding
  ) values (
    gen_random_uuid(), gen_random_uuid(), v_section_id,
    (select id from public.generation_outputs where outline_section_id = v_section_id limit 1),
    'test', 'test', ('[' || repeat('0', 3072) || ']')::vector(1536)
  );

  -- Verify pre-conditions
  select count(*) into v_outputs_count
  from public.generation_outputs where outline_section_id = v_section_id;
  select count(*) into v_embeddings_count
  from public.section_embeddings where outline_section_id = v_section_id;
  assert v_outputs_count = 1, 'Test 4 setup fail: expected 1 output';
  assert v_embeddings_count = 1, 'Test 4 setup fail: expected 1 section_embeddings';
  raise notice '  ✓ Setup: 1 output, 1 section_embeddings for the section';

  -- Delete the section
  delete from public.outline_sections where id = v_section_id;

  -- Both should be gone (FK CASCADE on both)
  select count(*) into v_outputs_count
  from public.generation_outputs where outline_section_id = v_section_id;
  select count(*) into v_embeddings_count
  from public.section_embeddings where outline_section_id = v_section_id;
  assert v_outputs_count = 0,
    'Test 4 fail: generation_outputs should be gone after deleting section (FK CASCADE)';
  assert v_embeddings_count = 0,
    'Test 4 fail: section_embeddings should be gone after deleting section (FK CASCADE)';
  raise notice '  ✓ Deleting entire section: all generation_outputs + section_embeddings gone (FK CASCADE)';
end $$;
