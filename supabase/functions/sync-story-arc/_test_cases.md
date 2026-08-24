# sync-story-arc — Manual Test Cases

Run against the deployed function or a local
`supabase functions serve sync-story-arc --env-file .env.local`. The function
accepts POST with a user JWT in `Authorization` and is
service-role-authenticating the DB writes.

## Prerequisites

```sh
# Get a JWT — replace with your local Supabase credentials
TOKEN=$(curl -s -X POST \
  "http://localhost:54321/auth/v1/token?grant_type=password" \
  -H "apikey: <anon-key>" \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"***"}' \
  | jq -r '.access_token')

BASE_URL="http://localhost:54321/functions/v1/sync-story-arc"
ANON_KEY="<anon-key>"
```

## Helper UUIDs

Replace these with new UUIDs per test run if you want a clean slate.

```sh
ARC_ID="11111111-1111-1111-1111-111111111111"
LINEAGE_ID="22222222-2222-2222-2222-222222222222"
TEMPLATE_ID="33333333-3333-3333-3333-333333333333"
BEAT1_ID="44444444-4444-4444-4444-444444444444"
BEAT2_ID="55555555-5555-5555-5555-555555555555"
PROJECT_LOCAL_ID="my-test-project-1"
```

---

## Case 1 — Missing Authorization → 401

```sh
curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{}'
# Expected: 401
```

## Case 2 — Missing `story_arc_id` → 400

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"local_project_id":"'"$PROJECT_LOCAL_ID"'","lineage_id":"'"$LINEAGE_ID"'","beats":[]}'
# Expected: 400 invalid_request — message "story_arc_id is required (UUID)"
```

## Case 3 — Happy path: create arc with 2 beats

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "story_arc_id": "'"$ARC_ID"'",
    "template_id": "'"$TEMPLATE_ID"'",
    "local_project_id": "'"$PROJECT_LOCAL_ID"'",
    "lineage_id": "'"$LINEAGE_ID"'",
    "customizations": {},
    "beats": [
      {"id":"'"$BEAT1_ID"'", "position":0, "role":"inciting_incident", "label":"The Spark", "details":"Setup details"},
      {"id":"'"$BEAT2_ID"'", "position":1, "role":"climax", "label":"The Storm", "details":"Climax details"}
    ]
  }'
# Expected: 200 — { story_arc_id, beats_upserted: 2, beats_deleted: 0 }
```

## Case 4 — Beat replace: drop one beat

Re-run Case 3 with only BEAT1 (omit BEAT2). BEAT2 should be deleted server-side;
BEAT1 retained with the same row data.

```sh
curl -s -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "story_arc_id": "'"$ARC_ID"'",
    "template_id": "'"$TEMPLATE_ID"'",
    "local_project_id": "'"$PROJECT_LOCAL_ID"'",
    "lineage_id": "'"$LINEAGE_ID"'",
    "customizations": {},
    "beats": [
      {"id":"'"$BEAT1_ID"'", "position":0, "role":"inciting_incident", "label":"The Spark", "details":"Setup details"}
    ]
  }'
# Expected: 200 — beats_upserted: 1, beats_deleted: 1
# Verify in Supabase: story_arc_beats has only BEAT1 row for ARC_ID.
# If any outline_sections previously referenced BEAT2, their story_arc_beat_id
# becomes NULL automatically via the FK ON DELETE SET NULL — no 500.
```

## Case 5 — Reorder beats (same IDs, swapped positions)

```sh
curl -s -X POST "$BASE_URL" -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d '{
    "story_arc_id": "'"$ARC_ID"'",
    "template_id": "'"$TEMPLATE_ID"'",
    "local_project_id": "'"$PROJECT_LOCAL_ID"'",
    "lineage_id": "'"$LINEAGE_ID"'",
    "customizations": {},
    "beats": [
      {"id":"'"$BEAT1_ID"'", "position":1, "role":"inciting_incident", "label":"The Spark", "details":"Setup details"},
      {"id":"'"$BEAT2_ID"'", "position":0, "role":"climax", "label":"The Storm", "details":"Climax details"}
    ]
  }'
# Expected: 200 — beats_upserted: 2 (positions overwritten), beats_deleted: 0
```

## Case 6 — Bad UUID in beat.id → 400

```sh
curl -s -w "\n%{http_code}" -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "story_arc_id": "'"$ARC_ID"'",
    "local_project_id": "'"$PROJECT_LOCAL_ID"'",
    "lineage_id": "'"$LINEAGE_ID"'",
    "beats": [{"id":"not-a-uuid", "position":0, "label":"x"}]
  }'
# Expected: 400 invalid_request — message "beat.id must be UUID"
```

## Case 7 — Empty beats list (arc with 0 beats — valid)

```sh
curl -s -X POST "$BASE_URL" -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d '{
    "story_arc_id": "'"$ARC_ID"'",
    "local_project_id": "'"$PROJECT_LOCAL_ID"'",
    "lineage_id": "'"$LINEAGE_ID"'",
    "beats": []
  }'
# Expected: 200 — beats_upserted: 0, beats_deleted: <prior count>
```

## Case 8 — Negative position → 400

```sh
curl -s -w "\n%{http_code}" -X POST "$BASE_URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "story_arc_id": "'"$ARC_ID"'",
    "local_project_id": "'"$PROJECT_LOCAL_ID"'",
    "lineage_id": "'"$LINEAGE_ID"'",
    "beats": [{"id":"'"$BEAT1_ID"'", "position":-1, "label":"x"}]
  }'
# Expected: 400 invalid_request — message "beat.position must be non-negative integer"
```

---

## Case 9 — Integration smoke: PR #284 burn fixed

This is the cross-function verification that the original 0/8 accept failure is
fixed.

1. Run Case 3 to put arc + beats on the server.
2. From the iOS app (with the v2 self-sync edit flows wired in a future PR),
   accept an AI-suggested section that has `story_arc_beat_id = BEAT1_ID`.
3. Verify in Supabase → `outline_sections` table → the new row has
   `story_arc_beat_id = BEAT1_ID` (no FK violation).

Or, without iOS, simulate via direct REST:

```sh
# Insert a section with story_arc_beat_id referencing BEAT1_ID — should succeed.
curl -s -X POST "http://localhost:54321/rest/v1/outline_sections" \
  -H "Authorization: Bearer $TOKEN" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "outline_id":"00000000-0000-0000-0000-000000000099",
    "position":0,
    "title":"Smoke",
    "summary":"smoke",
    "story_arc_beat_id":"'"$BEAT1_ID"'",
    "status":"draft"
  }'
# Expected: 201 created (no FK violation error)
```
