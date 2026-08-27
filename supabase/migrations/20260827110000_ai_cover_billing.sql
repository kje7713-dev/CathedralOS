-- AI cover generation is a material provider call. Reserve credits once per export
-- job, complete the usage event on success, and restore the exact source buckets
-- on failure. Edge Functions call these SECURITY DEFINER helpers with service role.

alter table public.user_credit_ledger
  add column if not exists related_export_job_id uuid references public.export_jobs(id) on delete set null;

create unique index if not exists user_credit_ledger_ai_cover_job_unique
  on public.user_credit_ledger (user_id, related_export_job_id)
  where reason = 'ai_cover_reservation' and related_export_job_id is not null;

alter table public.generation_usage_events
  drop constraint if exists generation_usage_events_purpose_check;
alter table public.generation_usage_events
  add constraint generation_usage_events_purpose_check
    check (purpose in ('generate', 'coherence-check', 'ai-cover'));

create unique index if not exists generation_usage_events_ai_cover_job_unique
  on public.generation_usage_events (user_id, idempotency_key)
  where purpose = 'ai-cover' and idempotency_key is not null;

create or replace function public.reserve_ai_cover_credits(
  p_user_id uuid,
  p_export_job_id uuid,
  p_cost integer,
  p_model_name text
)
returns table(available_credits integer, already_reserved boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  ent public.user_entitlements%rowtype;
  prior public.user_credit_ledger%rowtype;
  monthly_cost integer;
  purchased_cost integer;
begin
  if p_cost <= 0 then raise exception 'AI cover cost must be positive'; end if;

  select * into prior
    from public.user_credit_ledger
   where user_id = p_user_id
     and related_export_job_id = p_export_job_id
     and reason = 'ai_cover_reservation'
   limit 1;
  if prior.id is not null then
    select (monthly_credit_allowance + purchased_credit_balance)::integer
      into available_credits
      from public.user_entitlements where user_id = p_user_id;
    available_credits := coalesce(available_credits, 0);
    already_reserved := true;
    return next;
    return;
  end if;

  insert into public.user_entitlements (
    user_id, plan_name, is_pro, monthly_credit_allowance,
    purchased_credit_balance, entitlement_source
  ) values (p_user_id, 'free', false, 10, 0, 'monthly_grant')
  on conflict (user_id) do nothing;

  select * into ent from public.user_entitlements
   where user_id = p_user_id for update;

  if ent.monthly_credit_allowance + ent.purchased_credit_balance < p_cost then
    raise exception 'insufficient_ai_cover_credits: need %, have %',
      p_cost, ent.monthly_credit_allowance + ent.purchased_credit_balance;
  end if;

  monthly_cost := least(ent.monthly_credit_allowance, p_cost);
  purchased_cost := p_cost - monthly_cost;
  update public.user_entitlements
     set monthly_credit_allowance = monthly_credit_allowance - monthly_cost,
         purchased_credit_balance = purchased_credit_balance - purchased_cost
   where user_id = p_user_id;

  insert into public.user_credit_ledger (
    user_id, delta, reason, related_export_job_id, metadata
  ) values (
    p_user_id, -p_cost, 'ai_cover_reservation', p_export_job_id,
    jsonb_build_object('monthly_credits', monthly_cost,
                       'purchased_credits', purchased_cost,
                       'model_name', p_model_name)
  );

  insert into public.generation_usage_events (
    user_id, action, purpose, model_name, generation_length_mode,
    status, idempotency_key, credit_revenue_usd
  ) values (
    p_user_id, 'generate', 'ai-cover', p_model_name, 'short',
    'export-job:' || p_export_job_id::text, '0'
  );

  available_credits := ent.monthly_credit_allowance
    + ent.purchased_credit_balance - p_cost;
  already_reserved := false;
  return next;
end;
$$;

create or replace function public.complete_ai_cover_credits(
  p_user_id uuid, p_export_job_id uuid
)
returns void language sql security definer set search_path = public as $$
  update public.generation_usage_events
     set status = 'complete'
   where user_id = p_user_id
     and purpose = 'ai-cover'
     and idempotency_key = 'export-job:' || p_export_job_id::text;
$$;

create or replace function public.refund_ai_cover_credits(
  p_user_id uuid, p_export_job_id uuid
)
returns table(refunded boolean, available_credits integer)
language plpgsql security definer set search_path = public as $$
declare
  reservation public.user_credit_ledger%rowtype;
  monthly_restore integer;
  purchased_restore integer;
  already_refunded boolean;
begin
  select * into reservation from public.user_credit_ledger
   where user_id = p_user_id and related_export_job_id = p_export_job_id
     and reason = 'ai_cover_reservation' limit 1;
  if reservation.id is null then
    refunded := false; available_credits := 0; return next; return;
  end if;
  select exists(select 1 from public.user_credit_ledger
    where user_id = p_user_id and related_export_job_id = p_export_job_id
      and reason = 'ai_cover_refund') into already_refunded;
  if already_refunded then
    select monthly_credit_allowance + purchased_credit_balance into available_credits
      from public.user_entitlements where user_id = p_user_id;
    refunded := false; return next; return;
  end if;

  monthly_restore := coalesce((reservation.metadata->>'monthly_credits')::integer, 0);
  purchased_restore := coalesce((reservation.metadata->>'purchased_credits')::integer, 0);
  update public.user_entitlements
     set monthly_credit_allowance = monthly_credit_allowance + monthly_restore,
         purchased_credit_balance = purchased_credit_balance + purchased_restore
   where user_id = p_user_id;
  insert into public.user_credit_ledger (
    user_id, delta, reason, related_export_job_id, metadata
  ) values (p_user_id, -reservation.delta, 'ai_cover_refund', p_export_job_id,
            jsonb_build_object('reservation_id', reservation.id));
  update public.generation_usage_events
     set status = 'failed'
   where user_id = p_user_id and purpose = 'ai-cover'
     and idempotency_key = 'export-job:' || p_export_job_id::text;
  select monthly_credit_allowance + purchased_credit_balance into available_credits
    from public.user_entitlements where user_id = p_user_id;
  refunded := true; return next;
end;
$$;

revoke all on function public.reserve_ai_cover_credits(uuid, uuid, integer, text) from public, anon, authenticated;
revoke all on function public.complete_ai_cover_credits(uuid, uuid) from public, anon, authenticated;
revoke all on function public.refund_ai_cover_credits(uuid, uuid) from public, anon, authenticated;
notify pgrst, 'reload schema';
