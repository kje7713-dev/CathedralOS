-- Schedule the operator-only OpenAI Admin Usage reconciliation.
--
-- The Edge Function requires the Supabase service-role bearer token. Values are
-- deliberately read from Vault at invocation time; no credential is persisted
-- in migration text or the cron command.

create extension if not exists pg_net;

create or replace function public.invoke_openai_admin_usage_sync()
returns bigint
language plpgsql
security definer
set search_path = public, vault, net
as $$
declare
  project_url text;
  service_role_key text;
begin
  select decrypted_secret
    into project_url
    from vault.decrypted_secrets
   where name = 'project_url';
  select decrypted_secret
    into service_role_key
    from vault.decrypted_secrets
   where name = 'service_role_key';

  if project_url is null or service_role_key is null then
    raise exception 'openai admin usage scheduler secrets are not configured';
  end if;

  return net.http_post(
    url := rtrim(project_url, '/') || '/functions/v1/sync-openai-admin-usage',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_role_key
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 300000
  );
end;
$$;

revoke all on function public.invoke_openai_admin_usage_sync() from public, anon, authenticated;

do $$
begin
  if exists (
    select 1 from cron.job where jobname = 'openai-admin-usage-sync'
  ) then
    perform cron.unschedule('openai-admin-usage-sync');
  end if;

  perform cron.schedule(
    'openai-admin-usage-sync',
    '0 */6 * * *',
    $cmd$select public.invoke_openai_admin_usage_sync();$cmd$
  );
end;
$$;
