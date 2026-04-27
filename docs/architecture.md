# CathedralOS — Architecture

This document describes the internal architecture of CathedralOS: the data model hierarchy, the tiered field template system, the services layer, and the data flow between them.

---

## Data Model Hierarchy

```
StoryProject
├── ProjectSetting         (one, optional)
├── StoryCharacter[]
├── StoryRelationship[]    (references characters by ID)
├── ThemeQuestion[]
├── Motif[]
├── StorySpark[]
├── Aftertaste[]
├── PromptPack[]
│   └── (references entity IDs; builds export payload on demand)
└── GenerationOutput[]
    └── sourcePayloadJSON  (frozen snapshot of PromptPackExportPayload)
```

All models are SwiftData `@Model` classes persisted on-device. Child creation follows the pattern: `modelContext.insert(child)` then `parent.relationshipArray.append(child)`. Cascade-delete rules on the project ensure all children are removed when a project is deleted.

---

## Tiered Field Templates

Every story entity (`StoryCharacter`, `ProjectSetting`, `StorySpark`, `Aftertaste`, `StoryRelationship`, `ThemeQuestion`, `Motif`) stores two fields that control field visibility:

- `fieldLevel: String` — raw value of `FieldLevel` (`basic`, `advanced`, `literary`)
- `enabledFieldGroups: [String]` — raw values of `FieldGroupID` for groups explicitly enabled below their native level

### FieldLevel

```swift
enum FieldLevel: String {
    case basic, advanced, literary
}
```

### FieldGroupID

Each optional field group has a stable string identifier (e.g. `char.adv.psychology`, `setting.lit.culture`). These IDs are persisted in `enabledFieldGroups` and are backward-compatible across app versions.

### EntityFieldTemplate

Static per-entity definitions listing which groups belong to Advanced vs Literary:

```swift
EntityFieldTemplate.character   // advancedGroups: psychology, backstory, notes, bias
                                 // literaryGroups: innerLife, persona, arc, social
EntityFieldTemplate.setting
EntityFieldTemplate.spark
EntityFieldTemplate.aftertaste
EntityFieldTemplate.relationship
EntityFieldTemplate.themeQuestion
EntityFieldTemplate.motif
```

### FieldTemplateEngine

Shared engine consumed by every entity editor view. Three entry points:

| Method | Returns |
|---|---|
| `shouldShow(groupID:nativeLevel:currentLevel:enabledGroups:)` | Whether to render this group |
| `optionalAdvancedGroups(for:at:)` | Groups shown as opt-in toggles (Basic level only) |
| `optionalLiteraryGroups(for:at:)` | Groups shown as opt-in toggles (Basic and Advanced levels) |

**Visibility rules:**
- `basic` — only explicitly enabled groups are shown
- `advanced` — groups native to Advanced are always shown; Literary groups require opt-in
- `literary` — all groups shown unconditionally

---

## Services Layer

```
Services/
├── SupabaseConfiguration          Reads Info.plist; validates keys; isConfigured flag
├── BackendClient                  Protocol + SupabaseBackendClient implementation
├── AuthService                    Protocol + BackendAuthService stub
├── GenerationService              Protocol defining generate() / generateAction()
├── GenerationBackendService       Concrete backend implementation (wiring in progress)
├── GenerationServiceConfiguration Reads endpoint config from Info.plist
├── GenerationUsageTracker         UserDefaults-backed local usage event log
├── PublicSharingService           Protocol + BackendPublicSharingService (wiring in progress)
├── PublicSharingServiceConfiguration  Reads PublicSharingBaseURL from Info.plist
├── SharedOutputRemixMapper        Converts SharedOutputDetail → new StoryProject + PromptPack
├── FieldTemplateEngine            Shared tiered-field display logic (no network calls)
└── KeychainService                Keychain read/write helpers
```

**Key configuration pattern:** Services read credentials from `Info.plist` at runtime. No secrets are hardcoded. Missing configuration causes `isConfigured = false` and user-facing warnings, not crashes.

---

## DTOs and Export Payloads

### ProjectImportExportPayload

Used for the external LLM project-schema workflow. Schema key: `cathedralos.project_schema`, version `1`. Contains nested payloads for every entity type. See [`docs/schema-import-export.md`](schema-import-export.md).

### PromptPackExportPayload

Used for Prompt Pack export and as the `sourcePayloadJSON` snapshot on `GenerationOutput`. Schema key: `cathedralos.prompt_pack_export`, version `1`. Every section is always present — optional fields encode as empty strings or JSON `null` rather than being omitted.

### GenerationRequestDTO / GenerationResponseDTO

Request and response types for the `generate-story` Edge Function call. Request carries `sourcePayloadJSON`, `generationAction`, `generationLengthMode`, `outputBudget`, audience fields, and a `localGenerationID` for dedup. See [`generate-story-edge-function.md`](generate-story-edge-function.md).

---

## Generation Lineage

Each `GenerationOutput` tracks:

| Field | Purpose |
|---|---|
| `generationAction` | `generate` / `regenerate` / `continue` / `remix` |
| `parentGenerationID` | UUID of the parent output, if derived from one |
| `sourcePayloadJSON` | Frozen `PromptPackExportPayload` at generation time |
| `generationLengthMode` | `short` / `medium` / `long` / `chapter` |
| `outputBudget` | Token budget used |

This enables regenerate/continue/remix without requiring the original project data to be unchanged.

---

## Auth and Backend Flow (planned)

```
iOS App
  │  Supabase Auth (sign in / JWT)
  ▼
SupabaseBackendClient
  │  POST /functions/v1/generate-story
  │  Authorization: Bearer <user-jwt>
  ▼
Supabase Edge Function (generate-story)
  │  Verify JWT → user_id
  │  Call OpenAI (server-side only)
  │  INSERT generation_outputs
  │  INSERT generation_usage_events
  ▼
Postgres (RLS-protected tables)
```

The iOS app never receives or stores an OpenAI key. All generation is mediated by the Edge Function. The anon key is the only backend credential shipped in the app binary.

---

## Supabase Database Tables

| Table | Purpose |
|---|---|
| `profiles` | Optional display name per auth user |
| `generation_outputs` | Every AI-generated story/scene/chapter/outline |
| `generation_usage_events` | Immutable audit log of generation requests |
| `shared_outputs` | Denormalized snapshot for public sharing |
| `remix_events` | Lineage record of every remix action |

All tables have RLS enabled. See [`supabase-schema.md`](supabase-schema.md) for full schema details.
