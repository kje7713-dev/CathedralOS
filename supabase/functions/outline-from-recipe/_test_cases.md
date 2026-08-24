# outline-from-recipe — Test Cases

Phase 2 of novel-building per `docs/novel-building.md`. Takes a recipe
(PromptPack-shaped) + arc template (StoryArcTemplate-shaped) and returns 5-15
suggested `OutlineSection` payloads.

## Sample Request

```json
{
  "recipe": {
    "id": "uuid",
    "name": "Fred and Ted fuck America",
    "characters": [
      { "id": "char_1", "name": "Fred", "summary": "Suspended researcher" },
      { "id": "char_2", "name": "Ted", "summary": "Cold-war general" }
    ],
    "storySpark": {
      "id": "spark_1",
      "title": "Reactivated signal",
      "situation": "A reactivated Soviet signal",
      "stakes": "America's secrets"
    },
    "aftertaste": {
      "id": "at_1",
      "label": "Cold paranoia",
      "note": "The cost of suspicion"
    },
    "themes": [
      {
        "id": "t_1",
        "question": "Are bad people capable of good things?",
        "coreTension": "Trust vs suspicion"
      }
    ],
    "motifs": [
      { "id": "m_1", "label": "Skull in the smoke" }
    ],
    "notes": "Slow-burn psychological thriller"
  },
  "arcTemplate": {
    "id": "three-act",
    "name": "Three-Act",
    "description": "Classic three-act structure",
    "beats": [
      {
        "id": "beat_1",
        "role": "setup",
        "label": "Setup",
        "description": "Establish the world and characters"
      },
      {
        "id": "beat_2",
        "role": "inciting_incident",
        "label": "Inciting Incident",
        "description": "The signal reactivates"
      },
      {
        "id": "beat_3",
        "role": "first_plot_point",
        "label": "First Plot Point",
        "description": "Fred discovers the truth"
      },
      {
        "id": "beat_4",
        "role": "midpoint",
        "label": "Midpoint",
        "description": "The signal responds to Fred"
      },
      {
        "id": "beat_5",
        "role": "climax",
        "label": "Climax",
        "description": "Fred confronts Ted"
      },
      {
        "id": "beat_6",
        "role": "resolution",
        "label": "Resolution",
        "description": "The truth is buried"
      }
    ]
  },
  "hint": "Lean into cold-war paranoia"
}
```

## Sample Response (200)

```json
{
  "suggestions": [
    {
      "title": "The Signal Returns",
      "summary": "Fred, suspended from her post, watches the dormant Soviet signal pulse back to life on a basement oscilloscope. She has 48 hours before Ted's next briefing.",
      "container": "vignette",
      "pov": "thirdPersonLimited",
      "terminalBeat": "Fred watches the signal pulse and decides to act.",
      "storyArcBeatID": "beat_1"
    },
    {
      "title": "The Briefing",
      "summary": "Ted enters the SCIF. The signal is back and he wants Fred to confirm it's nothing. The shapes on the screen are familiar.",
      "container": "scene",
      "pov": "thirdPersonLimited",
      "terminalBeat": "Ted orders Fred to ignore the signal.",
      "storyArcBeatID": "beat_2"
    },
    {
      "title": "The Skull",
      "summary": "Fred cuts the oscilloscope tape and finds a pattern — the same pattern that was on the Soviet signal in 1972. She recognizes it from her mother's autopsy report.",
      "container": "scene",
      "pov": "firstPerson",
      "terminalBeat": "Fred finds the skull in the smoke.",
      "storyArcBeatID": "beat_3"
    },
    {
      "title": "Echo",
      "summary": "Fred sends the same pattern back. The signal responds. For the first time in 50 years, it's not a broadcast — it's a conversation.",
      "container": "moment",
      "pov": "firstPerson",
      "terminalBeat": "The signal answers Fred.",
      "storyArcBeatID": "beat_4"
    },
    {
      "title": "The Confrontation",
      "summary": "Fred confronts Ted in the empty SCIF. The oscilloscope shows the conversation playing back. Ted's hand trembles on the classified folder.",
      "container": "climax",
      "pov": "thirdPersonLimited",
      "terminalBeat": "Fred refuses to bury it.",
      "storyArcBeatID": "beat_5"
    },
    {
      "title": "What Remains",
      "summary": "The signal goes silent. The basement is colder now. Fred watches the oscilloscope and decides what comes next.",
      "container": "vignette",
      "pov": "firstPerson",
      "terminalBeat": "Fred walks away from the signal.",
      "storyArcBeatID": "beat_6"
    }
  ]
}
```

## Test Scenarios

### Success: 5-15 suggestions returned

- Input: valid recipe + arc template with 6+ beats
- Expected: `200`, returns 5-15 valid suggestions

### Failure: empty arc beats

- Input: `arcTemplate.beats = []`
- Expected: `400 invalid_request` "arcTemplate.id and non-empty
  arcTemplate.beats required"

### Failure: missing recipe

- Input: `{ "arcTemplate": { ... } }` (no `recipe`)
- Expected: `400 invalid_request` "recipe.id and recipe.name required"

### Failure: unauthorized

- Input: missing `Authorization` header
- Expected: `401 not_authenticated`

### Failure: rate limited

- Input: 6+ requests in 60 seconds
- Expected: `429 rate_limited` with `Retry-After` header

### Failure: invalid LLM response (drift)

- Input: forced mock to return malformed JSON
- Expected: `502 invalid_response`; invalid suggestions dropped, `warnings`
  returned

### Failure: server key missing

- Server-side: `OPENAI_API_KEY` not set
- Expected: `500 not_configured`

### Partial: beat not referenced

- Input: arc template with 6 beats, model returns 5 suggestions referencing only
  4 beats
- Expected: `200` with suggestions +
  `warnings: ["no suggestion references beat beat_5"]`

## Curl Example

```bash
curl -X POST https://<project-ref>.supabase.co/functions/v1/outline-from-recipe \
  -H "Authorization: Bearer <user-jwt>" \
  -H "Content-Type: application/json" \
  -d @request.json
```

## Setup

Required secrets (set via `supabase secrets set`):

```bash
supabase secrets set OPENAI_API_KEY=sk-...
# OPENAI_MODEL_DEFAULT is optional (default: gpt-4o-mini)
```

The structured-output schema requires `gpt-4o-mini` or newer.
