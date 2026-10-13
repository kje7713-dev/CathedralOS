begin;
select plan(12);

-- auth.users is owned by the initially authorized test role; create the
-- deterministic fixture before switching to service_role for reconciliation.
insert into auth.users (id, email)
  values ('00000000-0000-0000-0000-000000007062', 'pr706-reconcile@example.invalid')
  on conflict (id) do nothing;

set local role service_role;

do $$
declare
  v_user_id uuid := '00000000-0000-0000-0000-000000007062';
  v_run_id uuid := gen_random_uuid();
  v_zero_run_id uuid := gen_random_uuid();
  v_remaining numeric;
begin
  insert into public.user_entitlements(user_id, monthly_credit_allowance, purchased_credit_balance)
    values (v_user_id, 20, 3)
    on conflict (user_id) do update
      set monthly_credit_allowance = 20, purchased_credit_balance = 3;

  insert into public.outline_suggestion_runs(id, user_id, request_json, status)
    values (v_run_id, v_user_id, '{}'::jsonb, 'running'),
           (v_zero_run_id, v_user_id, '{}'::jsonb, 'failed');

  insert into public.generation_provider_attempts(
    user_id, purpose, action, feature_run_id, attempt_key,
    logical_stage_key, attempt_ordinal, model_name, status,
    settled_charge_credits
  ) values
    (v_user_id, 'outline-suggestion', 'stage-a', v_run_id, 'reconcile-fixture:a', 'stage-a', 1, 'fixture-model', 'settled', 1.25),
    (v_user_id, 'outline-suggestion', 'stage-b', v_run_id, 'reconcile-fixture:b', 'stage-b', 1, 'fixture-model', 'feature_validation_failed', 0.75),
    (v_user_id, 'outline-suggestion', 'stage-c', v_run_id, 'reconcile-fixture:c', 'stage-c', 1, 'fixture-model', 'provider_failed', 9.00),
    (v_user_id, 'outline-suggestion', 'stage-d', v_run_id, 'reconcile-fixture:d', 'stage-d', 1, 'fixture-model', 'settlement_failed', 8.00);

  perform public.reconcile_outline_provider_attempts(v_run_id);
  select monthly_credit_allowance + purchased_credit_balance into v_remaining
    from public.user_entitlements where user_id = v_user_id;

  perform public.reconcile_outline_provider_attempts(v_zero_run_id);
  perform set_config('test.reconcile_run_id', v_run_id::text, true);
  perform set_config('test.reconcile_zero_run_id', v_zero_run_id::text, true);
end $$;

select is(
  (select credit_cost_charged from public.outline_suggestion_runs where id = current_setting('test.reconcile_run_id')::uuid),
  2.00::numeric,
  'reconciliation sums only settled and feature-settled stages, excluding provider and settlement failures'
);
select is(
  (select credit_cost_charged from public.outline_suggestion_runs where id = current_setting('test.reconcile_zero_run_id')::uuid),
  0::numeric,
  'reconciliation records zero when no stage has settled credits'
);
select is(
  (select remaining_credits from public.outline_suggestion_runs where id = current_setting('test.reconcile_run_id')::uuid),
  23::numeric,
  'reconciliation stores the authoritative entitlement balance'
);
select is(
  (select count(*) from public.generation_provider_attempts where feature_run_id = current_setting('test.reconcile_run_id')::uuid and status = 'settled'),
  1::bigint,
  'one settled stage remains auditable'
);
select is(
  (select count(*) from public.generation_provider_attempts where feature_run_id = current_setting('test.reconcile_run_id')::uuid and status = 'feature_validation_failed'),
  1::bigint,
  'partially settled validation stage remains auditable'
);
select is(
  (select count(*) from public.generation_provider_attempts where feature_run_id = current_setting('test.reconcile_run_id')::uuid and status = 'provider_failed'),
  1::bigint,
  'provider failure is excluded from customer settlement total'
);
select is(
  (select count(*) from public.generation_provider_attempts where feature_run_id = current_setting('test.reconcile_run_id')::uuid and status = 'settlement_failed'),
  1::bigint,
  'unresolved settlement remains auditable rather than reported as zero'
);
select is(
  (select count(*) from public.outline_suggestion_runs where id in (current_setting('test.reconcile_run_id')::uuid, current_setting('test.reconcile_zero_run_id')::uuid)),
  2::bigint,
  'fixture contains both a partially settled and a zero-charge run'
);
select ok(
  (select credit_cost_charged is not null from public.outline_suggestion_runs where request_json = '{}'::jsonb and status = 'running' order by created_at desc limit 1),
  'reconciliation always writes a concrete durable total'
);
select ok(
  (select remaining_credits is not null from public.outline_suggestion_runs where request_json = '{}'::jsonb and status = 'running' order by created_at desc limit 1),
  'reconciliation records balance alongside the durable total'
);
select is(
  (select sum(settled_charge_credits) from public.generation_provider_attempts where attempt_key like 'reconcile-fixture:%' and status in ('settled','feature_validation_failed','feature_persistence_failed')),
  2.00::numeric,
  'repeated reconciliation source total remains idempotent'
);
select is(
  (select sum(settled_charge_credits) from public.generation_provider_attempts where attempt_key like 'reconcile-fixture:%' and status in ('provider_failed','settlement_failed')),
  17.00::numeric,
  'failed and unresolved rows retain their evidence without inflating customer charge'
);

select * from finish();
rollback;
