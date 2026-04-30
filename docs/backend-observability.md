# Backend Observability and Debugging Guide

This document describes how to inspect backend tables, diagnose common issues,
and understand the generation pipeline. All queries assume access to the
Supabase Studio SQL editor or the Supabase CLI with `supabase db shell`.

---

## Table of contents

1. [Tables overview](#tables-overview)
2. [Inspecting generation_request_logs](#inspecting-generation_request_logs)
3. [Inspecting generation_usage_events](#inspecting-generation_usage_events)
4. [Inspecting user_credit_ledger](#inspecting-user_credit_ledger)
5. [Inspecting user_entitlements](#inspecting-user_entitlements)
6. [Inspecting generation_outputs](#inspecting-generation_outputs)
7. [Common troubleshooting](#common-troubleshooting)
8. [Health check function](#health-check-function)

---

## Tables overview

| Table | Purpose |
|---|---|
| `generation_request_logs` | Structured metadata log for every generation attempt (rate limiting + observability). No raw prompt text. |
| `generation_usage_events` | Per-generation event log including token counts and model. |
| `user_credit_ledger` | Immutable audit trail of all credit movements (charges and grants). |
| `user_entitlements` | Current credit balances and plan state per user. |
| `generation_outputs` | Generated text rows with source payload snapshot. |

---

## Inspecting generation_request_logs

`generation_request_logs` is the primary observability table. Every request
that passes authentication is logged here (success, failure, rate-limited,
insufficient credits). Raw prompt text is **never** stored.

### All recent requests for a user

```sql
SELECT
  id,
  request_id,
  action,
  generation_length_mode,
  output_budget,
  status,
  error_code,
  error_message,
  model_name,
  input_tokens,
  output_tokens,
  duration_ms,
  created_at
FROM generation_request_logs
WHERE user_id = '<user-uuid>'
ORDER BY created_at DESC
LIMIT 50;
```

### Failed requests in the last hour

```sql
SELECT *
FROM generation_request_logs
WHERE user_id = '<user-uuid>'
  AND status != 'success'
  AND created_at > now() - interval '1 hour'
ORDER BY created_at DESC;
```

### Rate-limited events across all users (last 24 hours)

```sql
SELECT
  user_id,
  count(*) AS rate_limited_count,
  max(created_at) AS last_hit
FROM generation_request_logs
WHERE error_code = 'rate_limited'
  AND created_at > now() - interval '24 hours'
GROUP BY user_id
ORDER BY rate_limited_count DESC;
```

### Request volume by status (last 7 days)

```sql
SELECT
  status,
  error_code,
  count(*) AS count,
  avg(duration_ms) AS avg_duration_ms,
  percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms) AS p95_duration_ms
FROM generation_request_logs
WHERE created_at > now() - interval '7 days'
GROUP BY status, error_code
ORDER BY count DESC;
```

### Slowest successful requests (last 24 hours)

```sql
SELECT
  user_id,
  action,
  generation_length_mode,
  duration_ms,
  input_tokens,
  output_tokens,
  created_at
FROM generation_request_logs
WHERE status = 'success'
  AND created_at > now() - interval '24 hours'
ORDER BY duration_ms DESC
LIMIT 20;
```

---

## Inspecting generation_usage_events

`generation_usage_events` records the outcome of each LLM call including
token counts and model name.

### Usage for a user (last 30 days)

```sql
SELECT
  action,
  model_name,
  generation_length_mode,
  input_tokens,
  output_tokens,
  status,
  created_at
FROM generation_usage_events
WHERE user_id = '<user-uuid>'
ORDER BY created_at DESC
LIMIT 50;
```

### Token usage by model (last 7 days)

```sql
SELECT
  model_name,
  count(*) AS requests,
  sum(input_tokens) AS total_input_tokens,
  sum(output_tokens) AS total_output_tokens,
  avg(input_tokens) AS avg_input_tokens,
  avg(output_tokens) AS avg_output_tokens
FROM generation_usage_events
WHERE status = 'complete'
  AND created_at > now() - interval '7 days'
GROUP BY model_name;
```

### Failed provider calls (last 24 hours)

```sql
SELECT
  user_id,
  action,
  model_name,
  generation_length_mode,
  created_at
FROM generation_usage_events
WHERE status = 'failed'
  AND created_at > now() - interval '24 hours'
ORDER BY created_at DESC;
```

---

## Inspecting user_credit_ledger

`user_credit_ledger` is the immutable audit trail of every credit movement.
Use it to verify charges, track grants, and investigate credit discrepancies.

### All ledger entries for a user

```sql
SELECT
  id,
  delta,
  reason,
  related_generation_output_id,
  related_transaction_id,
  metadata,
  created_at
FROM user_credit_ledger
WHERE user_id = '<user-uuid>'
ORDER BY created_at DESC
LIMIT 50;
```

### Check that a specific generation was charged

```sql
SELECT *
FROM user_credit_ledger
WHERE related_generation_output_id = '<generation-output-uuid>'
  AND reason = 'generation_charge';
```

### Total credits charged vs granted for a user

```sql
SELECT
  reason,
  sum(delta) AS total_delta,
  count(*) AS entries
FROM user_credit_ledger
WHERE user_id = '<user-uuid>'
GROUP BY reason
ORDER BY reason;
```

### Verify no double-charge occurred

A correctly functioning system will have at most one `generation_charge`
ledger row per `generation_output_id`:

```sql
SELECT
  related_generation_output_id,
  count(*) AS charge_count
FROM user_credit_ledger
WHERE reason = 'generation_charge'
GROUP BY related_generation_output_id
HAVING count(*) > 1;
-- Should return 0 rows if no double-charges have occurred.
```

---

## Inspecting user_entitlements

`user_entitlements` holds the current credit balance and plan state for each user.

### Current balance for a user

```sql
SELECT
  user_id,
  plan_name,
  is_pro,
  monthly_credit_allowance,
  purchased_credit_balance,
  monthly_credit_allowance + purchased_credit_balance AS available_credits,
  current_period_start,
  current_period_end,
  entitlement_source,
  updated_at
FROM user_entitlements
WHERE user_id = '<user-uuid>';
```

### Users with zero credits (may be out of credits)

```sql
SELECT
  user_id,
  plan_name,
  monthly_credit_allowance,
  purchased_credit_balance,
  updated_at
FROM user_entitlements
WHERE monthly_credit_allowance = 0
  AND purchased_credit_balance = 0
ORDER BY updated_at DESC;
```

### Manually grant credits to a user (admin operation)

Use the Supabase service-role client or SQL editor. Never use the anon client.

```sql
-- 1. Update the balance
UPDATE user_entitlements
SET monthly_credit_allowance = monthly_credit_allowance + 10
WHERE user_id = '<user-uuid>';

-- 2. Insert a ledger entry for auditability
INSERT INTO user_credit_ledger (user_id, delta, reason, metadata)
VALUES ('<user-uuid>', 10, 'admin_adjustment', '{"note": "Support grant"}');
```

---

## Inspecting generation_outputs

`generation_outputs` stores the generated text and source payload for each
successful generation.

### Recent outputs for a user

```sql
SELECT
  id,
  local_generation_id,
  project_name,
  prompt_pack_name,
  title,
  generation_action,
  generation_length_mode,
  model_name,
  status,
  visibility,
  created_at
FROM generation_outputs
WHERE user_id = '<user-uuid>'
ORDER BY created_at DESC
LIMIT 20;
```

### Check if a specific local generation ID was synced

```sql
SELECT id, title, status, created_at
FROM generation_outputs
WHERE local_generation_id = '<local-uuid>';
```

---

## Common troubleshooting

### Insufficient credits

**Symptom:** iOS shows "Not enough credits" or backend returns 402.

```sql
-- Check current balance
SELECT
  monthly_credit_allowance,
  purchased_credit_balance,
  monthly_credit_allowance + purchased_credit_balance AS available
FROM user_entitlements
WHERE user_id = '<user-uuid>';

-- Review recent charges
SELECT delta, reason, created_at
FROM user_credit_ledger
WHERE user_id = '<user-uuid>'
ORDER BY created_at DESC
LIMIT 10;
```

**Resolution:** Grant credits via admin adjustment (see above) or advise the
user to purchase a credit pack or wait for monthly reset.

---

### Auth failure

**Symptom:** Backend returns 401 / `errorCode: "unauthenticated"`.

1. Verify the user is signed in (check Supabase Auth → Users for the account).
2. Check that the iOS app is sending the `Authorization: Bearer <jwt>` header.
3. Verify the JWT has not expired (default Supabase access token TTL is 1 hour).
4. Check `SUPABASE_URL` and `SUPABASE_ANON_KEY` are set correctly in the app.

```sql
-- Verify the user exists in Supabase Auth
SELECT id, email, created_at, last_sign_in_at
FROM auth.users
WHERE id = '<user-uuid>';
```

---

### Provider timeout

**Symptom:** Backend returns 504 / `errorCode: "provider_timeout"`. Credits
are not charged.

1. Check `generation_request_logs` for recent `provider_timeout` entries:

```sql
SELECT user_id, duration_ms, created_at
FROM generation_request_logs
WHERE error_code = 'provider_timeout'
  AND created_at > now() - interval '1 hour'
ORDER BY created_at DESC;
```

2. If timeouts are widespread, the OpenAI API may be degraded. Check
   https://status.openai.com for incident reports.
3. Consider reducing `OPENAI_MODEL_DEFAULT` to a faster model if timeouts
   are frequent for chapter-length generations.

---

### Missing OpenAI secret

**Symptom:** Backend returns 500 / `errorCode: "backend_config_missing"`.
The health check reports `openaiKeyConfigured: false`.

```sh
# Verify secrets are set
supabase secrets list

# Set the missing secret
supabase secrets set OPENAI_API_KEY=sk-...
supabase secrets set OPENAI_MODEL_DEFAULT=gpt-4o-mini

# Redeploy the function after setting secrets
supabase functions deploy generate-story
```

---

### Rate limited

**Symptom:** Backend returns 429 / `errorCode: "rate_limited"`. The iOS app
shows a retry countdown.

```sql
-- Check recent request volume for the user
SELECT
  status,
  count(*) AS count,
  min(created_at) AS earliest,
  max(created_at) AS latest
FROM generation_request_logs
WHERE user_id = '<user-uuid>'
  AND created_at > now() - interval '1 hour'
GROUP BY status;

-- Check for suspicious patterns (many failed requests)
SELECT error_code, count(*)
FROM generation_request_logs
WHERE user_id = '<user-uuid>'
  AND created_at > now() - interval '1 hour'
GROUP BY error_code;
```

**Legitimate use:** The user is generating too quickly. The iOS client will
display a countdown using `retryAfterSeconds`.

**Abuse pattern:** Many failed requests in a short period may indicate
automated probing. Review the `generation_request_logs` error codes.

---

## Health check function

The `backend-health` Edge Function provides a quick operational status check.

```sh
# Call the health check
curl "https://<project-ref>.supabase.co/functions/v1/backend-health" \
  -H "apikey: <anon-key>"
```

### Example healthy response

```json
{
  "status": "ok",
  "timestamp": "2026-04-30T22:00:00.000Z",
  "checks": {
    "openaiKeyConfigured": true,
    "openaiModel": "gpt-4o-mini",
    "supabaseURLConfigured": true,
    "serviceRoleKeyConfigured": true,
    "databaseReachable": true
  },
  "generationFunctionConfigured": true
}
```

### Example degraded response

```json
{
  "status": "degraded",
  "timestamp": "2026-04-30T22:00:00.000Z",
  "checks": {
    "openaiKeyConfigured": false,
    "openaiModel": "gpt-4o-mini (default)",
    "supabaseURLConfigured": true,
    "serviceRoleKeyConfigured": true,
    "databaseReachable": true
  },
  "generationFunctionConfigured": false,
  "dbError": null
}
```

The health check returns HTTP `200` when all checks pass, or `503` when any
required check fails. Secret values are never included in the response.

### Serve the health check locally

```sh
supabase functions serve backend-health --env-file .env.local
curl http://localhost:54321/functions/v1/backend-health
```
