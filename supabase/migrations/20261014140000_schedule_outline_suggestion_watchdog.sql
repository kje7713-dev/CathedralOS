-- Autonomous recovery for durable outline suggestion workers.
-- This migration wires the watchdog; it does not execute production changes
-- until explicitly applied. The cron invocation uses Vault at runtime.
create extension if not exists pg_cron;
create extension if not exists pg_net;

create or replace function public.invoke_outline_suggestion_watchdog()
returns bigint
language plpgsql
security definer
set search_path = public, vault, net
as $$
declare
  project_url text;
  supabase_secret_key text;
begin
  select decrypted_secret into project_url from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into supabase_secret_key from vault.decrypted_secrets where name = 'supabase_secret_key';
  if project_url is null or supabase_secret_key is null then
    raise exception 'outline watchdog scheduler secrets are not configured';
  end if;
  return net.http_post(
    url := rtrim(project_url, '/') || '/functions/v1/outline-suggestion-watchdog',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', supabase_secret_key),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
end;
$$;

revoke all on function public.invoke_outline_suggestion_watchdog() from public, anon, authenticated;
grant execute on function public.invoke_outline_suggestion_watchdog() to service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'outline-suggestion-watchdog') then
    perform cron.unschedule('outline-suggestion-watchdog');
  end if;
  perform cron.schedule(
    'outline-suggestion-watchdog',
    '* * * * *',
    $cmd$select public.invoke_outline_suggestion_watchdog();$cmd$
  );
end;
$$;
