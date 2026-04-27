# CathedralOS — Project Schema Import/Export

This document describes the external LLM authoring workflow: how to export a CathedralOS project schema, have an LLM fill it, and import the result back into the app.

---

## Overview

The schema import/export workflow lets you draft an entire story project in an external LLM and bring it into CathedralOS as normal editable app data.

**Workflow:**

1. **Export** a project schema from CathedralOS (copy or share JSON).
2. **Paste** it into any LLM with a prompt asking it to fill in the story details.
3. **Copy** the LLM's JSON response.
4. **Import** it into CathedralOS. The project becomes fully editable.

---

## Schema Envelope

Every project schema payload must have:

```json
{
  "schema": "cathedralos.project_schema",
  "version": 1,
  "project": { ... },
  "setting": null,
  "characters": [],
  "storySparks": [],
  "aftertastes": [],
  "relationships": [],
  "themeQuestions": [],
  "motifs": []
}
```

| Field | Requirement |
|---|---|
| `schema` | Must be exactly `cathedralos.project_schema` |
| `version` | Must be integer `1` |
| All other keys | Must be present; arrays may be empty; `setting` may be `null` |

---

## Strict JSON Rules

- The payload **must be strict valid JSON**. The parser does not accept:
  - Smart/curly quotes (`"`, `"`, `'`, `'`)
  - Em dashes or other typographic punctuation in JSON structural positions
  - Trailing commas
  - Comments
- If an LLM returns Markdown code fences, strip them before importing.
- All text content inside string values may use any Unicode characters.

---

## Relationship ID Rules

Relationships reference characters by ID. The `sourceCharacterID` and `targetCharacterID` fields must match the `id` field of a character in the same payload.

**Example — using explicit IDs:**
```json
{
  "characters": [
    { "id": "char-001", "name": "Aria", ... },
    { "id": "char-002", "name": "Marcus", ... }
  ],
  "relationships": [
    {
      "id": "rel-001",
      "name": "Mentor–Student",
      "sourceCharacterID": "char-001",
      "targetCharacterID": "char-002",
      ...
    }
  ]
}
```

If relationship IDs do not match any character in the payload, the import will fail validation or create orphaned relationships.

---

## Field Depth in Imported Entities

Each entity in the payload carries `fieldLevel` and `enabledFieldGroups` fields. These control which fields are visible in the editor after import.

| `fieldLevel` | Behaviour |
|---|---|
| `"basic"` | Only core fields + any explicitly enabled groups are shown |
| `"advanced"` | Advanced fields shown by default; Literary groups require opt-in |
| `"literary"` | All fields shown |

When asking an LLM to fill a schema, instruct it to set `fieldLevel` to the depth appropriate for the entity's detail level, and populate the corresponding fields.

---

## Entity Payload Reference

### Project

```json
{
  "name": "String",
  "summary": "String",
  "notes": "String",
  "tags": [],
  "readingLevel": "String (e.g. middle_grade, young_adult, adult)",
  "contentRating": "String (e.g. g, pg, pg13, r)",
  "audienceNotes": "String"
}
```

### Setting (optional — set to `null` to omit)

```json
{
  "summary": "String",
  "domains": ["String"],
  "constraints": ["String"],
  "themes": ["String"],
  "season": "String",
  "worldRules": ["String"],
  "historicalPressure": "String",
  "politicalForces": "String",
  "socialOrder": "String",
  "environmentalPressure": "String",
  "technologyLevel": "String",
  "mythicFrame": "String",
  "instructionBias": "String",
  "religiousPressure": "String",
  "economicPressure": "String",
  "taboos": ["String"],
  "institutions": ["String"],
  "dominantValues": ["String"],
  "hiddenTruths": ["String"],
  "fieldLevel": "basic",
  "enabledFieldGroups": []
}
```

### Character

```json
{
  "id": "String (stable ID; must match any relationship references)",
  "name": "String",
  "roles": ["String"],
  "goals": ["String"],
  "preferences": ["String"],
  "resources": ["String"],
  "failurePatterns": ["String"],
  "fears": ["String"],
  "flaws": ["String"],
  "secrets": ["String"],
  "wounds": ["String"],
  "contradictions": ["String"],
  "needs": ["String"],
  "obsessions": ["String"],
  "attachments": ["String"],
  "notes": "String",
  "instructionBias": "String",
  "selfDeceptions": ["String"],
  "identityConflicts": ["String"],
  "moralLines": ["String"],
  "breakingPoints": ["String"],
  "virtues": ["String"],
  "publicMask": "String",
  "privateLogic": "String",
  "speechStyle": "String",
  "arcStart": "String",
  "arcEnd": "String",
  "coreLie": "String",
  "coreTruth": "String",
  "reputation": "String",
  "status": "String",
  "fieldLevel": "basic",
  "enabledFieldGroups": []
}
```

### StorySpark

```json
{
  "id": "String",
  "title": "String",
  "situation": "String",
  "stakes": "String",
  "twist": "String",
  "urgency": "String",
  "threat": "String",
  "opportunity": "String",
  "complication": "String",
  "clock": "String",
  "triggerEvent": "String",
  "initialImbalance": "String",
  "falseResolution": "String",
  "reversalPotential": "String",
  "fieldLevel": "basic",
  "enabledFieldGroups": []
}
```

### Aftertaste

```json
{
  "id": "String",
  "label": "String",
  "note": "String",
  "emotionalResidue": "String",
  "endingTexture": "String",
  "desiredAmbiguityLevel": "String",
  "readerQuestionLeftOpen": "String",
  "lastImageFeeling": "String",
  "fieldLevel": "basic",
  "enabledFieldGroups": []
}
```

### Relationship

```json
{
  "id": "String",
  "name": "String",
  "sourceCharacterID": "String (must match a character id in this payload)",
  "targetCharacterID": "String (must match a character id in this payload)",
  "relationshipType": "String",
  "tension": "String",
  "loyalty": "String",
  "fear": "String",
  "desire": "String",
  "dependency": "String",
  "history": "String",
  "powerBalance": "String",
  "resentment": "String",
  "misunderstanding": "String",
  "unspokenTruth": "String",
  "whatEachWantsFromTheOther": "String",
  "whatWouldBreakIt": "String",
  "whatWouldTransformIt": "String",
  "notes": "String",
  "fieldLevel": "basic",
  "enabledFieldGroups": []
}
```

### ThemeQuestion

```json
{
  "id": "String",
  "question": "String",
  "coreTension": "String",
  "valueConflict": "String",
  "moralFaultLine": "String",
  "endingTruth": "String",
  "notes": "String",
  "fieldLevel": "basic",
  "enabledFieldGroups": []
}
```

### Motif

```json
{
  "id": "String",
  "label": "String",
  "category": "String",
  "meaning": "String",
  "examples": ["String"],
  "notes": "String",
  "fieldLevel": "basic",
  "enabledFieldGroups": []
}
```

---

## Suggested LLM Prompt

When exporting a blank schema to fill with an LLM, use a prompt similar to:

```
You are a story consultant. I am giving you a structured project schema for the story app CathedralOS.
Fill in all fields with a compelling, internally consistent story world.
Use only strict valid JSON — no smart quotes, no trailing commas, no Markdown formatting.
Return the complete JSON object only.

[paste exported schema here]
```

---

## After Import

Once a schema is imported:

- The project appears in the Projects list and is fully editable.
- All entity fields are editable in the normal forms.
- You can build Prompt Packs, export for generation, or continue developing the project manually.
- The `notes` field on the project can store remix provenance or other metadata from the import.
