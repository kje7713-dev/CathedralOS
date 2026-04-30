# generate-story — Manual Test Cases

These cases document the expected behaviour of the `generate-story` Edge
Function. Run them with `curl` against a locally-served function
(`supabase functions serve generate-story --env-file .env.local`) or against
the hosted project.

---

## Prerequisites

```sh
# Obtain a valid user JWT (replace values with your local Supabase credentials)
TOKEN=$(curl -s -X POST \
  "http://localhost:54321/auth/v1/token?grant_type=password" \
  -H "apikey: <anon-key>" \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"testpassword"}' \
  | jq -r '.access_token')

BASE_URL="http://localhost:54321/functions/v1/generate-story"
ANON_KEY="<anon-key>"
```

---

## Case 1 — Missing auth header → 401

```sh
curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sourcePayloadJSON": {},
    "generationAction": "generate",
    "generationLengthMode": "short",
    "outputBudget": 800
  }'
# Expected: 401
```

---

## Case 2 — Invalid token → 401

```sh
curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL" \
  -H "Authorization: Bearer not-a-real-jwt" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sourcePayloadJSON": {},
    "generationAction": "generate",
    "generationLengthMode": "short",
    "outputBudget": 800
  }'
# Expected: 401
```

---

## Case 3 — Invalid generationAction → 422

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sourcePayloadJSON": {"characters": []},
    "generationAction": "teleport",
    "generationLengthMode": "short",
    "outputBudget": 800
  }'
# Expected: 422
# Expected body contains: "Invalid generationAction"
```

---

## Case 4 — Invalid generationLengthMode → 422

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sourcePayloadJSON": {"characters": []},
    "generationAction": "generate",
    "generationLengthMode": "epic",
    "outputBudget": 800
  }'
# Expected: 422
# Expected body contains: "Invalid generationLengthMode"
```

---

## Case 5 — Excessive outputBudget is capped to server max

The server silently clamps `outputBudget` to the per-mode maximum.
A valid short request with `outputBudget: 99999` should succeed and the
response should show `outputBudget: 800` (the short-mode cap).

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sourcePayloadJSON": {"characters": []},
    "generationAction": "generate",
    "generationLengthMode": "short",
    "outputBudget": 99999
  }'
# Expected: 200, body.outputBudget === 800
```

---

## Case 6 — Missing sourcePayloadJSON → 422

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "generationAction": "generate",
    "generationLengthMode": "short",
    "outputBudget": 800
  }'
# Expected: 422
# Expected body contains: "sourcePayloadJSON is required"
```

---

## Case 7 — continue without previousOutputText → 422

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sourcePayloadJSON": {"characters": []},
    "generationAction": "continue",
    "generationLengthMode": "medium",
    "outputBudget": 1600
  }'
# Expected: 422
# Expected body contains: "previousOutputText is required"
```

---

## Case 8 — Successful generation

Requires `OPENAI_API_KEY` to be configured in your `.env.local` file.

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "projectName": "Test Project",
    "promptPackName": "Adventure Pack",
    "sourcePayloadJSON": {
      "schema": "cathedralos.prompt_pack_export",
      "version": 1,
      "project": {"id": "00000000-0000-0000-0000-000000000001", "name": "Test Project"},
      "promptPack": {"id": "00000000-0000-0000-0000-000000000002", "name": "Adventure Pack", "prompts": []}
    },
    "generationAction": "generate",
    "generationLengthMode": "short",
    "outputBudget": 800,
    "readingLevel": "Middle Grade",
    "contentRating": "PG",
    "audienceNotes": "Suitable for ages 8-12",
    "localGenerationID": "test-local-id-001"
  }'
# Expected: 200
# Expected body contains: status "complete", generatedText, title, modelName
# Verify in Supabase Studio: a row exists in generation_outputs and generation_usage_events
```

---

## Case 9 — Provider failure returns failed status

Temporarily set `OPENAI_API_KEY=invalid` in `.env.local` and re-serve the function.

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sourcePayloadJSON": {"characters": []},
    "generationAction": "generate",
    "generationLengthMode": "short",
    "outputBudget": 800
  }'
# Expected: 502
# Expected body: { "status": "failed", "errorMessage": "Generation failed: ..." }
# Verify in Supabase Studio: a row exists in generation_usage_events with status "failed"
# No row should exist in generation_outputs
```

---

## Case 10 — Insufficient credits returns 402

First, ensure the user has 0 available credits:
- In Supabase Studio, set `user_entitlements.monthly_credit_allowance = 0`
  and `purchased_credit_balance = 0` for the test user.

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sourcePayloadJSON": {"characters": []},
    "generationAction": "generate",
    "generationLengthMode": "short",
    "outputBudget": 800
  }'
# Expected: 402
# Expected body:
# {
#   "status": "failed",
#   "errorCode": "insufficient_credits",
#   "errorMessage": "Insufficient credits for this generation.",
#   "requiredCredits": 1,
#   "availableCredits": 0
# }
# Verify in Supabase Studio: NO row in generation_outputs, NO row in user_credit_ledger
```

---

## Case 11 — Sufficient credits allows generation and charges

Ensure the user has >= 1 available credit.

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sourcePayloadJSON": {
      "schema": "cathedralos.prompt_pack_export",
      "version": 1,
      "project": {"id": "00000000-0000-0000-0000-000000000001", "name": "Test Project"},
      "promptPack": {"id": "00000000-0000-0000-0000-000000000002", "name": "Adventure Pack", "prompts": []}
    },
    "generationAction": "generate",
    "generationLengthMode": "short",
    "outputBudget": 800
  }'
# Expected: 200
# Expected body includes: status "complete", creditCostCharged: 1, remainingCredits: N-1
# Verify in Supabase Studio:
#   - generation_outputs row exists
#   - user_credit_ledger row exists with delta = -1, reason = "generation_charge"
#   - user_entitlements.monthly_credit_allowance decremented by 1
```

---

## Case 12 — Provider failure does NOT charge credits

Set `OPENAI_API_KEY=invalid` and ensure user has credits.

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sourcePayloadJSON": {"characters": []},
    "generationAction": "generate",
    "generationLengthMode": "short",
    "outputBudget": 800
  }'
# Expected: 502
# Verify in Supabase Studio:
#   - NO new row in user_credit_ledger (no charge)
#   - user_entitlements balance unchanged
#   - generation_usage_events row with status "failed" (existing audit behaviour)
```

---

## Automated test patterns

A test suite can inject a mock `LLMProvider` and a mock `CreditStore` via the
exported `handler` function in `index.ts`. See `index_test.ts` for examples.

```ts
import { handler } from "./index.ts";
import type { LLMProvider, LLMMessage } from "./_provider.ts";
import type { CreditStore, UserEntitlement } from "./_credits.ts";

const mockProvider: LLMProvider = {
  async complete(_messages: LLMMessage[], _maxTokens: number) {
    return {
      content: "Once upon a time...",
      modelName: "mock-model",
      inputTokens: 10,
      outputTokens: 20,
    };
  },
};

const mockCreditStore: CreditStore = {
  async loadOrDefault(_userId) {
    return {
      user_id: _userId,
      plan_name: "free",
      is_pro: false,
      monthly_credit_allowance: 10,
      purchased_credit_balance: 0,
      current_period_start: null,
      current_period_end: null,
      entitlement_source: "monthly_grant",
      updated_at: new Date().toISOString(),
    };
  },
  async charge(_userId, _cost, ent, _outputId) {
    return { ...ent, monthly_credit_allowance: ent.monthly_credit_allowance - _cost };
  },
};

// Inject mockProvider as 2nd argument and mockCreditStore as 3rd argument.
// await handler(req, mockProvider, mockCreditStore);
```


---

## Case 13 — Rate limit exceeded (per minute)

Trigger the rate limit by sending more than 5 requests within a 60-second window.

```sh
for i in {1..6}; do
  curl -s -o /dev/null -w "Request $i: %{http_code}\n"     -X POST "$BASE_URL"     -H "Authorization: Bearer $TOKEN"     -H "apikey: $ANON_KEY"     -H "Content-Type: application/json"     -d '{"sourcePayloadJSON":{"characters":[]},"generationAction":"generate","generationLengthMode":"short","outputBudget":800}'
done
# Expected: requests 1–5 return 200 or another status (credits/provider permitting)
#           request 6 returns 429 with errorCode "rate_limited" and retryAfterSeconds
```

Expected rate-limited response body:
```json
{
  "status": "failed",
  "errorCode": "rate_limited",
  "errorMessage": "Too many requests. Please wait before generating again.",
  "retryAfterSeconds": 60
}
```

Verify in Supabase Studio:
- `generation_request_logs` contains a row with `status = 'rate_limited'`
- No `generation_outputs` or `user_credit_ledger` row for the rate-limited request

---

## Case 14 — Oversized sourcePayloadJSON rejected → 422

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"sourcePayloadJSON\": \"$(python3 -c 'print("x" * 50001)')\"
    \"generationAction\": \"generate\",
    \"generationLengthMode\": \"short\",
    \"outputBudget\": 800
  }"
# Expected: 422
# Expected body: { "errorCode": "invalid_request", "errorMessage": "sourcePayloadJSON exceeds maximum size..." }
```

---

## Case 15 — Oversized previousOutputText rejected → 422

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"sourcePayloadJSON\": {},
    \"generationAction\": \"continue\",
    \"generationLengthMode\": \"medium\",
    \"outputBudget\": 1600,
    \"previousOutputText\": \"$(python3 -c 'print("x" * 20001)')\",
  }"
# Expected: 422
# Expected body: { "errorCode": "invalid_request", "errorMessage": "previousOutputText exceeds maximum size..." }
```

---

## Case 16 — Provider timeout maps to provider_timeout

Set `OPENAI_API_KEY=sk-fake-key-that-causes-immediate-401` and serve the function.
Alternatively configure a local proxy that holds connections open.

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"sourcePayloadJSON":{"characters":[]},"generationAction":"generate","generationLengthMode":"short","outputBudget":800}'
# For a fake key → Expected: 502 with errorCode "provider_rejected"
# For a timeout scenario → Expected: 504 with errorCode "provider_timeout"
# Verify: no credit charge in user_credit_ledger
# Verify: generation_request_logs row with error_code = 'provider_timeout' or 'provider_rejected'
```

---

## Case 17 — Successful generation logs request metadata

After a successful generation (Case 8):

```sql
-- In Supabase Studio SQL editor
SELECT
  request_id,
  action,
  generation_length_mode,
  output_budget,
  status,
  model_name,
  input_tokens,
  output_tokens,
  duration_ms,
  created_at
FROM generation_request_logs
WHERE user_id = '<your-user-uuid>'
ORDER BY created_at DESC
LIMIT 1;
-- Expected: status = 'success', model_name set, input_tokens / output_tokens > 0
```

---

## Case 18 — Failed generation logs request metadata without charging

After a failed generation (Case 9 — invalid API key):

```sql
SELECT *
FROM generation_request_logs
WHERE user_id = '<your-user-uuid>'
ORDER BY created_at DESC
LIMIT 1;
-- Expected: status = 'failed', error_code = 'provider_rejected' or similar

SELECT *
FROM user_credit_ledger
WHERE user_id = '<your-user-uuid>'
ORDER BY created_at DESC
LIMIT 1;
-- Expected: NO new row with reason = 'generation_charge' from the failed attempt
```

---

## Case 19 — Health check does not expose secrets

```sh
curl -s "https://<project-ref>.supabase.co/functions/v1/backend-health" \
  -H "apikey: $ANON_KEY"
# Expected: 200 (when configured) or 503 (when degraded)
# Expected: JSON contains openaiKeyConfigured (boolean), NOT the key value itself
# Expected: JSON does NOT contain the string "sk-" or any secret value
```

---

## Automated test patterns (rate limiting)

The rate limiter can be tested by injecting a `MockRateLimitStore` via the
`handler()` fourth argument. See `index_test.ts` for examples.

```ts
import { handler } from "./index.ts";
import type { RateLimitStore, RateLimitResult } from "./_rate_limiter.ts";

const rateLimitedStore: RateLimitStore = {
  async checkLimits(_userId) {
    return { allowed: false, retryAfterSeconds: 60 };
  },
  async recordRequest(_userId, _params) {},
};

// Inject as 4th argument. Rate limit check fires before credit check.
// await handler(req, mockProvider, mockCreditStore, rateLimitedStore);
```
