#!/usr/bin/env bash
# scripts/smoke_test.sh — verify the deployed generate-story edge function
# accepts existingSections and respects them in the generated output.
#
# Validates the existing-sections feature shipped in PR #292/#293 by:
#   1. Authenticating as a real Supabase user (email/password)
#   2. POSTing a generation request with two existing sections that contain
#      distinctive phrases (named characters, dates, objects)
#   3. Verifying the function returns 200 + valid output_text
#   4. Verifying the output does NOT contain those distinctive phrases
#      (which would mean the model duplicated existing prose instead of
#      treating it as context)
#
# Required env:
#   SUPABASE_PROJECT_REF    e.g. abcdefghij.supabase.co (no https://)
#   SUPABASE_ANON_KEY       from Supabase dashboard → Settings → API
#   SUPABASE_EMAIL          a real account with credits
#   SUPABASE_PASSWORD       password for that account
#
# Usage:
#   export SUPABASE_PROJECT_REF=...
#   export SUPABASE_ANON_KEY=...
#   export SUPABASE_EMAIL=...
#   export SUPABASE_PASSWORD=...
#   ./scripts/smoke_test.sh
#
# Exit codes:
#   0  PASS
#   1  FAIL (function error, missing output, or duplicated phrases)
#   2  SETUP error (missing env var or missing dependency)
#
# Notes:
#   - Costs ~1-2 credits per run (small LLM call against medium budget).
#   - Consumes 1 slot of the per-user rate limit (5/min, 30/hr).
#   - Persists one generation_outputs row to the DB.
#   - The estimate action could be used for a free ping check (no LLM call)
#     but won't validate existing-sections behaviour end-to-end.

set -euo pipefail

# --- Dependency check ---
for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "✗ SETUP: missing dependency '$cmd'" >&2
    exit 2
  fi
done

# --- Env check ---
for var in SUPABASE_PROJECT_REF SUPABASE_ANON_KEY SUPABASE_EMAIL SUPABASE_PASSWORD; do
  if [[ -z "${!var:-}" ]]; then
    echo "✗ SETUP: missing env var $var" >&2
    exit 2
  fi
done

BASE_URL="https://${SUPABASE_PROJECT_REF}"
FUNC_URL="${BASE_URL}/functions/v1/generate-story"

# --- 1. Get user JWT ---
echo "→ Logging in as ${SUPABASE_EMAIL}..."
TOKEN=$(curl -sf -X POST \
  "${BASE_URL}/auth/v1/token?grant_type=password" \
  -H "apikey: ${SUPABASE_ANON_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${SUPABASE_EMAIL}\",\"password\":\"${SUPABASE_PASSWORD}\"}" \
  | jq -r '.access_token // empty')

if [[ -z "$TOKEN" ]]; then
  echo "✗ FAIL: could not obtain JWT (check email/password)" >&2
  exit 1
fi
echo "✓ Got JWT (${#TOKEN} chars)"

# --- 2. Build payload ---
EXISTING_SECTIONS='[
  {
    "id": "s1",
    "title": "The Inheritance",
    "content": "Mara arrived at her grandmother'\''s cliffside cottage in Maine. On the kitchen table sat a sealed envelope addressed to her, dated 1952."
  },
  {
    "id": "s2",
    "title": "The Diary",
    "content": "She opened the diary. The first entry was about a man named Hollis who had vanished from the village the previous winter."
  }
]'

PAYLOAD=$(jq -n \
  --argjson sections "$EXISTING_SECTIONS" \
  '{
    sourcePayloadJSON: {
      recipe: "A woman inherits her grandmother'\''s cliffside cottage in Maine and discovers a diary that hints at a decades-old disappearance. Continue the story with a new scene.",
      existingSections: $sections,
      container: "scene"
    },
    generationAction: "generate",
    generationLengthMode: "medium",
    outputBudget: 1600,
    container: "scene"
  }')

# --- 3. POST ---
echo "→ POST ${FUNC_URL}"
RESPONSE=$(curl -sf -X POST "${FUNC_URL}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "apikey: ${SUPABASE_ANON_KEY}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  || true)

if [[ -z "$RESPONSE" ]]; then
  echo "✗ FAIL: empty response from function (check project ref + anon key)" >&2
  exit 1
fi

# --- 4. Validate shape ---
STATUS=$(echo "$RESPONSE" | jq -r '.status // "unknown"')
OUTPUT=$(echo "$RESPONSE" | jq -r '.output_text // .output // empty')

if [[ "$STATUS" != "complete" && "$STATUS" != "draft" ]]; then
  echo "✗ FAIL: status=${STATUS}"
  echo "$RESPONSE" | jq . >&2
  exit 1
fi

if [[ -z "$OUTPUT" ]]; then
  echo "✗ FAIL: no output_text in response"
  echo "$RESPONSE" | jq . >&2
  exit 1
fi
echo "✓ Output: ${#OUTPUT} chars (status=${STATUS})"

# --- 5. Check forbidden phrases (case-insensitive) ---
# These are taken verbatim from the existing sections. If the model
# duplicates any of them in new output, it failed to treat existing
# prose as context.
FORBIDDEN=(
  "sealed envelope addressed to her"
  "dated 1952"
  "man named Hollis"
  "vanished from the village"
)

DUPES=()
for phrase in "${FORBIDDEN[@]}"; do
  if echo "$OUTPUT" | grep -qiF "$phrase"; then
    DUPES+=("$phrase")
  fi
done

if [[ ${#DUPES[@]} -gt 0 ]]; then
  echo
  echo "✗ FAIL: output duplicated existing-section phrases:"
  printf '  - "%s"\n' "${DUPES[@]}"
  echo
  echo "=== OUTPUT (first 1500 chars) ==="
  echo "${OUTPUT:0:1500}"
  echo "=== END ==="
  exit 1
fi

echo "✓ Output does not duplicate existing section content"
echo
echo "✓ PASS"
