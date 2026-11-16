-- Harden paid synopsis operations without creating a second billing ledger.
alter table public.epub_synopsis_operations
  add column if not exists claim_token text,
  add column if not exists claimed_at timestamptz,
  add column if not exists provider_model text,
  add column if not exists provider_input_tokens integer,
  add column if not exists provider_output_tokens integer,
  add column if not exists provider_cached_input_tokens integer,
  add column if not exists provider_cache_write_input_tokens integer,
  add column if not exists provider_tool_cost_usd numeric;

create or replace function public.claim_epub_synopsis_operation(
  p_user_id uuid,
  p_operation_id text,
  p_project_id text,
  p_title text,
  p_source_fingerprint text
)
returns table(
  claim_status text,
  claim_token text,
  synopsis text,
  provider_model text,
  provider_input_tokens integer,
  provider_output_tokens integer,
  provider_cached_input_tokens integer,
  provider_cache_write_input_tokens integer,
  provider_tool_cost_usd numeric
)
language plpgsql security definer set search_path = public as $$
declare existing public.epub_synopsis_operations%rowtype;
  new_token text := gen_random_uuid()::text;
begin
  select * into existing
    from public.epub_synopsis_operations
   where user_id = p_user_id and operation_id = p_operation_id
   for update;

  if existing.user_id is null then
    insert into public.epub_synopsis_operations (
      user_id, operation_id, project_id, title, source_fingerprint,
      status, claim_token, claimed_at
    ) values (
      p_user_id, p_operation_id, p_project_id, p_title, p_source_fingerprint,
      'pending', new_token, now()
    );
    return query select 'claimed'::text, new_token, null::text, null::text,
      null::integer, null::integer, null::integer, null::integer, null::numeric;
    return;
  end if;

  if existing.project_id is distinct from p_project_id
     or existing.title is distinct from p_title
     or existing.source_fingerprint is distinct from p_source_fingerprint then
    raise exception 'synopsis operation identity was reused for different source';
  end if;

  if existing.status = 'complete' then
    return query select 'complete'::text, null::text, existing.synopsis,
      existing.provider_model, existing.provider_input_tokens,
      existing.provider_output_tokens, existing.provider_cached_input_tokens,
      existing.provider_cache_write_input_tokens, existing.provider_tool_cost_usd;
    return;
  end if;

  -- A checkpointed result remains owned by the original worker while its
  -- claim lease is active. It may be recovered only after the lease expires
  -- (or after the owner explicitly releases it following a failed attempt).
  if existing.synopsis is not null then
    if existing.claimed_at is not null and existing.claimed_at > now() - interval '10 minutes' then
      return query select 'in_progress'::text, null::text, null::text, null::text,
        null::integer, null::integer, null::integer, null::integer, null::numeric;
      return;
    end if;
    update public.epub_synopsis_operations
       set claim_token = new_token, claimed_at = now()
     where user_id = p_user_id and operation_id = p_operation_id
       and status = 'pending'
       and (claimed_at is null or claimed_at <= now() - interval '10 minutes');
    return query select 'ready'::text, new_token, existing.synopsis,
      existing.provider_model, existing.provider_input_tokens,
      existing.provider_output_tokens, existing.provider_cached_input_tokens,
      existing.provider_cache_write_input_tokens, existing.provider_tool_cost_usd;
    return;
  end if;

  if existing.claimed_at is not null and existing.claimed_at > now() - interval '10 minutes' then
    return query select 'in_progress'::text, null::text, null::text, null::text,
      null::integer, null::integer, null::integer, null::integer, null::numeric;
    return;
  end if;

  update public.epub_synopsis_operations
     set claim_token = new_token, claimed_at = now()
   where user_id = p_user_id and operation_id = p_operation_id;
  return query select 'claimed'::text, new_token, null::text, null::text,
    null::integer, null::integer, null::integer, null::integer, null::numeric;
end; $$;

revoke all on function public.claim_epub_synopsis_operation(uuid,text,text,text,text) from public;
grant execute on function public.claim_epub_synopsis_operation(uuid,text,text,text,text) to service_role;

notify pgrst, 'reload schema';
