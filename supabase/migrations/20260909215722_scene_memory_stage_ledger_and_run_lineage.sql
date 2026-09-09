-- Scene-memory lifecycle safety: durable stage identity, atomic settlement,
-- authenticated Run All output lineage, and bounded prior-memory lookup.
-- Forward-only migration; do not edit the historical billing/run migrations.

alter table public.generation_usage_events
  add column if not exists stage_identity text,
  add column if not exists stage_version text,
  add column if not exists stage_status text;

alter table public.generation_usage_events
  drop constraint if exists generation_usage_events_stage_status_check;
alter table public.generation_usage_events
  add constraint generation_usage_events_stage_status_check
  check (stage_status is null or stage_status in ('started', 'complete', 'failed'));

create unique index if not exists generation_usage_events_stage_identity_unique
  on public.generation_usage_events (user_id, stage_identity)
  where stage_identity is not null;

create index if not exists idx_generation_usage_events_stage_lookup
  on public.generation_usage_events (user_id, generation_output_id, purpose, stage_status);

alter table public.generation_outputs
  add column if not exists run_id uuid references public.chapter_runs(id) on delete set null,
  add column if not exists run_section_id uuid references public.outline_sections(id) on delete set null;

create unique index if not exists generation_outputs_run_section_unique
  on public.generation_outputs (run_id, run_section_id)
  where run_id is not null and run_section_id is not null;

create index if not exists idx_generation_outputs_run_lineage
  on public.generation_outputs (run_id, run_section_id, user_id, project_local_id);

create index if not exists idx_section_embeddings_project_section
  on public.section_embeddings (project_id, outline_section_id);

create index if not exists idx_outline_sections_outline_position
  on public.outline_sections (outline_id, position);

-- The usage event and the entitlement debit are one transaction. A duplicate
-- stage is successful only when the immutable parameters match the prior
-- completed stage; a mismatched retry fails closed.
create or replace function public.settle_scene_memory_stage(
  p_user_id uuid,
  p_stage_identity text,
  p_stage_version text,
  p_stage text,
  p_output_id uuid,
  p_model_name text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_charge integer,
  p_provider_cogs_cents numeric default null,
  p_customer_revenue_cents numeric default null,
  p_margin_cents numeric default null
)
returns table(settlement_status text, usage_event_id uuid, remaining_credits integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  prior public.generation_usage_events%rowtype;
  ent public.user_entitlements%rowtype;
  new_monthly integer;
  new_purchased integer;
  ledger_id uuid;
begin
  if p_stage_identity is null or length(trim(p_stage_identity)) = 0 then
    raise exception 'stage identity required';
  end if;
  if p_charge < 0 then raise exception 'stage charge cannot be negative'; end if;

  select * into prior
    from public.generation_usage_events
   where user_id = p_user_id
     and stage_identity = p_stage_identity
   for update;

  -- The pre-versioning implementation used output_id:stage as its
  -- idempotency key. Fall back only when the versioned identity is absent;
  -- never let an unrelated legacy row win an OR query.
  if prior.id is null then
    select * into prior
      from public.generation_usage_events
     where user_id = p_user_id
       and generation_output_id = p_output_id
       and purpose = 'embed-section'
       and status = 'complete'
       and idempotency_key = p_output_id::text || ':' || p_stage
     for update;
  end if;

  if prior.id is not null then
    if prior.status <> 'complete'
       or prior.generation_output_id is distinct from p_output_id
       or prior.action is distinct from p_stage
       or prior.model_name is distinct from p_model_name
       or prior.input_tokens is distinct from p_input_tokens
       or prior.output_tokens is distinct from p_output_tokens
       or (prior.stage_identity is not null and (
         prior.stage_status <> 'complete'
         or prior.stage_version is distinct from p_stage_version
         or round(coalesce(prior.credit_revenue_usd, 0)::numeric, 6)
            is distinct from round((p_charge::numeric * 0.05), 6)
       )) then
      raise exception 'stage identity parameters do not match prior settlement';
    end if;
    select (monthly_credit_allowance + purchased_credit_balance)::integer
      into remaining_credits from public.user_entitlements where user_id = p_user_id;
    return query select 'duplicate'::text, prior.id, coalesce(remaining_credits, 0);
    return;
  end if;

  select * into ent from public.user_entitlements where user_id = p_user_id for update;
  if ent.user_id is null then
    raise exception 'entitlement missing for user %', p_user_id;
  end if;
  if ent.monthly_credit_allowance + ent.purchased_credit_balance < p_charge then
    raise exception 'insufficient credits for stage';
  end if;

  new_monthly := greatest(0, ent.monthly_credit_allowance - p_charge);
  new_purchased := ent.purchased_credit_balance - greatest(0, p_charge - ent.monthly_credit_allowance);
  update public.user_entitlements
     set monthly_credit_allowance = new_monthly,
         purchased_credit_balance = new_purchased
   where user_id = p_user_id;

  insert into public.generation_usage_events (
    user_id, generation_output_id, action, purpose, model_name,
    input_tokens, output_tokens, generation_length_mode, output_budget,
    status, credit_revenue_usd, stage_identity, stage_version, stage_status,
    provider_cogs_cents, customer_revenue_cents, margin_cents
  ) values (
    p_user_id, p_output_id, p_stage, 'embed-section', p_model_name,
    p_input_tokens, p_output_tokens, 'section-memory', p_output_tokens,
    'complete', p_charge * 0.05, p_stage_identity, p_stage_version, 'complete',
    p_provider_cogs_cents, p_customer_revenue_cents, p_margin_cents
  ) returning id into ledger_id;

  insert into public.user_credit_ledger (
    user_id, delta, reason, related_generation_output_id, metadata
  ) values (
    p_user_id, -p_charge, 'generation_charge', p_output_id,
    jsonb_build_object('stage_identity', p_stage_identity, 'stage_version', p_stage_version, 'stage', p_stage)
  );

  return query select 'settled'::text, ledger_id,
    (new_monthly + new_purchased)::integer;
end;
$$;

revoke all on function public.settle_scene_memory_stage(uuid, text, text, text, uuid, text, integer, integer, integer, numeric, numeric, numeric) from public;
grant execute on function public.settle_scene_memory_stage(uuid, text, text, text, uuid, text, integer, integer, integer, numeric, numeric, numeric) to service_role;

notify pgrst, 'reload schema';


-- Renew only the lease owned by this worker attempt. An expired worker cannot
-- extend or clear a lease taken by a replacement worker.
create or replace function public.renew_chapter_run_lease(
  p_run_id uuid,
  p_worker_attempt integer,
  p_lease_seconds integer default 420
) returns boolean
language sql security definer set search_path = public as $$
  update public.chapter_runs
     set worker_lease_until = now() + make_interval(secs => greatest(p_lease_seconds, 30))
   where id = p_run_id
     and status = 'running'
     and worker_attempt = p_worker_attempt
     and worker_lease_until > now()
  returning true;
$$;
revoke all on function public.renew_chapter_run_lease(uuid, integer, integer) from public;
grant execute on function public.renew_chapter_run_lease(uuid, integer, integer) to service_role;
