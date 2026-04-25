# generate-story — Supabase Edge Function

Authenticated story-generation endpoint for CathedralOS.
The iOS app sends a structured prompt packet; this function calls the LLM
provider server-side, stores the result, and returns generated text.

**Never place the OpenAI API key in the iOS app.** It is held exclusively
in Supabase function secrets and never shipped to the client binary.

---

## Table of contents

1. [Architecture overview](#architecture-overview)
2. [Environment secrets](#environment-secrets)
3. [Local development](#local-development)
4. [Deploying to production](#deploying-to-production)
5. [Request contract](#request-contract)
6. [Response contract](#response-contract)
7. [Example curl request](#example-curl-request)
8. [Database writes](#database-writes)
9. [Security notes](#security-notes)

---

## Architecture overview

```
iOS App (SupabaseBackendClient)
    │  POST /functions/v1/generate-story
    │  Authorization: Bearer <user-jwt>
    ▼
Supabase Edge Function (generate-story/index.ts)
    │  1. Verify JWT → derive user_id
    │  2. Validate request body
    │  3. Build prompt from sourcePayloadJSON
    │  4. Call OpenAI via _provider.ts (secret key — never touches client)
    │  5. Insert generation_outputs row
    │  6. Insert generation_usage_events row
    │  7. Return generated text
    ▼
Postgres (generation_outputs + generation_usage_events)
```

---

## Environment secrets

Set these using the Supabase CLI. **Do not commit any secret value.**

| Secret | Required | Description |
|---|---|---|
| `OPENAI_API_KEY` | Yes | OpenAI secret key for LLM calls |
| `OPENAI_MODEL_DEFAULT` | No | Model for normal generation (default: `gpt-4o-mini`) |
| `OPENAI_MODEL_PREMIUM` | No | Reserved for a future premium tier |

### Set secrets locally (`.env.local`)

Create a file named `.env.local` in the repository root (add it to
`.gitignore` — it must never be committed):

```sh
# .env.local — NEVER COMMIT THIS FILE
OPENAI_API_KEY=sk-...
OPENAI_MODEL_DEFAULT=gpt-4o-mini
```

### Set secrets in the hosted project

```sh
supabase secrets set OPENAI_API_KEY=sk-...
supabase secrets set OPENAI_MODEL_DEFAULT=gpt-4o-mini

# Verify
supabase secrets list
```

---

## Local development

### Prerequisites

- [Supabase CLI](https://supabase.com/docs/guides/cli) ≥ 1.x
- [Deno](https://deno.land/) ≥ 1.40 (used by the Edge Functions runtime)
- Docker (required by `supabase start`)

### Start local Supabase

```sh
supabase start
```

Local credentials (URL, anon key, service-role key) are printed to the
terminal. Use the printed anon key in your `.env.local` and iOS test builds.

### Apply the database schema

```sh
supabase db push
```

### Serve the function locally

```sh
supabase functions serve generate-story --env-file .env.local
```

The function is now available at:
```
http://localhost:54321/functions/v1/generate-story
```

---

## Deploying to production

### Link your hosted project (once)

```sh
supabase link --project-ref YOUR_PROJECT_REF
```

### Deploy the function

```sh
supabase functions deploy generate-story
```

### Set production secrets (if not already done)

```sh
supabase secrets set OPENAI_API_KEY=sk-...
supabase secrets set OPENAI_MODEL_DEFAULT=gpt-4o-mini
```

The deployed function URL will be:
```
https://<project-ref>.supabase.co/functions/v1/generate-story
```

---

## Request contract

**Method:** `POST`  
**Content-Type:** `application/json`  
**Authorization:** `Bearer <supabase-user-jwt>`

### Body fields

| Field | Type | Required | Description |
|---|---|---|---|
| `sourcePayloadJSON` | object or string | **Yes** | Serialized `PromptPackExportPayload` |
| `generationAction` | string | **Yes** | `generate` / `regenerate` / `continue` / `remix` |
| `generationLengthMode` | string | **Yes** | `short` / `medium` / `long` / `chapter` |
| `outputBudget` | number | **Yes** | Requested token budget (capped server-side) |
| `projectName` | string | No | Human-readable project label (defaults to `""`) |
| `promptPackName` | string | No | Prompt pack name (defaults to `""`) |
| `previousOutputText` | string | **Yes for `continue`** | Prior generated text |
| `readingLevel` | string | No | e.g. `"Middle Grade"` |
| `contentRating` | string | No | e.g. `"PG"` |
| `audienceNotes` | string | No | Free-form audience guidance |
| `localGenerationID` | string | No | Client-side UUID for dedup / linking |

### Server-enforced output budget caps

| Mode | Max tokens |
|---|---|
| `short` | 800 |
| `medium` | 1 600 |
| `long` | 3 000 |
| `chapter` | 6 000 |

If the client sends a higher value, the server silently clamps it to the cap.

---

## Response contract

### Success (`200`)

```json
{
  "generatedText": "Once upon a time...",
  "title": "The Dragon's Keep",
  "modelName": "gpt-4o-mini",
  "generationAction": "generate",
  "generationLengthMode": "short",
  "outputBudget": 800,
  "inputTokens": 342,
  "outputTokens": 617,
  "status": "complete"
}
```

### Error

```json
{
  "status": "failed",
  "errorMessage": "Human-readable description of what went wrong"
}
```

| HTTP status | Meaning |
|---|---|
| `401` | Missing or invalid JWT |
| `400` | Malformed JSON body |
| `405` | Wrong HTTP method |
| `422` | Validation error (invalid enum value, missing required field) |
| `500` | Server configuration error |
| `502` | LLM provider call failed |

---

## Example curl request

```sh
# 1. Sign in and capture the token
TOKEN=$(curl -s -X POST \
  "https://<project-ref>.supabase.co/auth/v1/token?grant_type=password" \
  -H "apikey: <anon-key>" \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"yourpassword"}' \
  | jq -r '.access_token')

# 2. Call the function
curl -X POST \
  "https://<project-ref>.supabase.co/functions/v1/generate-story" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: <anon-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "projectName": "The Dragon Chronicles",
    "promptPackName": "Fantasy Adventure",
    "sourcePayloadJSON": {
      "schema": "cathedralos.prompt_pack_export",
      "version": 1,
      "project": {
        "id": "00000000-0000-0000-0000-000000000001",
        "name": "The Dragon Chronicles"
      },
      "promptPack": {
        "id": "00000000-0000-0000-0000-000000000002",
        "name": "Fantasy Adventure",
        "prompts": []
      }
    },
    "generationAction": "generate",
    "generationLengthMode": "short",
    "outputBudget": 800,
    "readingLevel": "Young Adult",
    "contentRating": "PG",
    "audienceNotes": "Ages 13+, action-focused",
    "localGenerationID": "local-abc-123"
  }'
```

---

## Database writes

On a successful generation the function inserts:

### `generation_outputs`

| Column | Value |
|---|---|
| `user_id` | Derived from JWT (never from the request body) |
| `local_generation_id` | `localGenerationID` if provided |
| `project_name` | `projectName` (defaults to `""`) |
| `prompt_pack_name` | `promptPackName` (defaults to `""`) |
| `title` | Extracted from generated text heading, or pack/project name |
| `output_text` | Full generated text |
| `source_payload_json` | `sourcePayloadJSON` as JSONB |
| `model_name` | Model name reported by the provider |
| `generation_action` | Validated `generationAction` |
| `generation_length_mode` | Validated `generationLengthMode` |
| `output_budget` | Server-capped budget |
| `status` | `"complete"` |
| `visibility` | `"private"` |

### `generation_usage_events`

| Column | Value |
|---|---|
| `user_id` | From JWT |
| `generation_output_id` | UUID of the inserted output row (nullable on insert failure) |
| `action` | `generationAction` |
| `model_name` | Model name |
| `input_tokens` | Reported by provider (nullable) |
| `output_tokens` | Reported by provider (nullable) |
| `generation_length_mode` | `generationLengthMode` |
| `output_budget` | Server-capped budget |
| `status` | `"complete"` or `"failed"` |

A `generation_usage_events` row with `status: "failed"` is inserted even when
the LLM provider call fails, so usage anomalies can be audited. No
`generation_outputs` row is inserted on failure.

---

## Security notes

### OpenAI API key

- **Never** place `OPENAI_API_KEY` in the iOS app, `.xcconfig` files, or
  any file committed to source control.
- The key lives exclusively in Supabase function secrets, accessible only
  to server-side code running inside the Edge Function runtime.
- Rotate the key immediately if it is ever accidentally exposed.

### Supabase service-role key

- The function uses the **anon key** (passed by the iOS client in
  `Authorization`) together with RLS policies that restrict each user to
  their own rows.
- The service-role key is not required by this function and must never be
  sent to or stored in the iOS app.

### user_id derivation

The `user_id` written to the database is always derived from the verified
Supabase JWT on the server. The function never reads `user_id` from the
request body, preventing a caller from impersonating another user.

### Input validation

- `generationAction` and `generationLengthMode` are validated against an
  allowlist before any LLM call is made.
- `outputBudget` is clamped to a server-enforced maximum — the client
  cannot request an arbitrarily large generation.
- `sourcePayloadJSON` is required; the function returns `422` if it is absent.
