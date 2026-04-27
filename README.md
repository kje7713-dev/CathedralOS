# CathedralOS

[![iOS CI](https://github.com/kje7713-dev/CathedralOS/actions/workflows/ios.yml/badge.svg?branch=main)](https://github.com/kje7713-dev/CathedralOS/actions/workflows/ios.yml)

CathedralOS is a structured story and worldbuilding app for iOS. It helps writers build rich projects — characters, settings, relationships, themes, motifs, story sparks, and aftertastes — and then export that structure for LLM-powered story generation.

**What it supports today:**
- Manual project building with tiered field templates (Basic / Advanced / Literary)
- Project schema import/export for external LLM authoring workflows
- Prompt Pack JSON/markdown export for LLM generation
- Saved generation output scaffolding with lineage tracking (continue / remix)
- Audience controls (reading level, content rating, audience notes)

**Planned / in progress:**
- Backend-backed generation via Supabase Edge Functions + OpenAI
- Public sharing and remix of generated outputs
- Saved output sync to Supabase Postgres

---

## Core Concepts

| Model | Description |
|---|---|
| `StoryProject` | Top-level container. Owns all other entities. Holds name, summary, notes, and audience metadata. |
| `ProjectSetting` | The world of the story — domains, constraints, themes, season, world rules, cultural pressures. One per project. |
| `StoryCharacter` | A story character with tiered fields: roles/goals (Basic), psychology/backstory (Advanced), inner life/arc (Literary). |
| `StoryRelationship` | A directional connection between two characters — type, tension, loyalty, history, power balance, and transformation potential. |
| `ThemeQuestion` | A thematic question the story explores. At Literary depth adds moral fault lines and ending truths. |
| `Motif` | A recurring symbol or image. At Advanced depth adds meaning and examples. |
| `StorySpark` | A story premise — situation, stakes, twist. At Advanced depth adds urgency/threat/clock. At Literary depth adds structural beats. |
| `Aftertaste` | The emotional residue a reader should feel after the story ends. At Literary depth captures the final image and open questions. |
| `PromptPack` | A curated subset of project entities assembled for LLM generation. Exports a canonical structured packet. |
| `GenerationOutput` | A saved AI-generated story, scene, chapter, or outline. Tracks status, lineage (action/parent), length mode, publishing metadata. |

---

## Tiered Field Templates

Every entity supports three depth levels. The level is stored per entity — different characters in the same project can be at different levels.

| Level | Purpose |
|---|---|
| **Basic** | Fast Mad-Libs-style input. Core fields only. |
| **Advanced** | Deeper story control — psychology, history, forces, structure. |
| **Literary** | High-control narrative/literary craft — inner life, arc, moral fault lines, hidden truths. |

**Selective opt-in:** at Basic or Advanced, individual higher-level field groups can be enabled without switching the whole entity to a higher level. For example, a Basic character can enable "Inner Life & Deceptions" without enabling all Literary fields.

**Architecture files:**
- `FieldLevel` — `basic` / `advanced` / `literary` enum
- `FieldGroupID` — stable string identifiers for every optional group across all entity types
- `EntityFieldTemplate` — static per-entity templates listing which groups belong to Advanced vs Literary
- `FieldTemplateEngine` — shared logic for `shouldShow`, `optionalAdvancedGroups`, `optionalLiteraryGroups`

See [`docs/architecture.md`](docs/architecture.md) for a deeper walkthrough.

---

## Audience Controls

Every `StoryProject` carries three optional fields that guide generated output suitability:

| Field | Example |
|---|---|
| `readingLevel` | `middle_grade`, `young_adult`, `adult` |
| `contentRating` | `g`, `pg`, `pg13`, `r` |
| `audienceNotes` | `Keep horror spooky but not graphic.` |

These are included in Prompt Pack exports and passed to the generation backend.

---

## External LLM Workflows

### Project Schema Import/Export

Export a project to JSON, fill it in an external LLM, and import it back as a fully editable project.

**Workflow:**
1. Export a project schema from the app (copy or share JSON).
2. Paste into any LLM with instructions to fill the schema.
3. Paste/import the returned JSON back into CathedralOS.
4. The imported project becomes normal editable app data.

**Schema rules:**
- `schema` must be `cathedralos.project_schema`
- `version` must be integer `1`
- Must be strict valid JSON (smart quotes and typographic punctuation are not valid)
- Relationship `sourceCharacterID` / `targetCharacterID` must match character IDs in the same payload

See [`docs/schema-import-export.md`](docs/schema-import-export.md) for the full payload reference and LLM prompt guidance.

### Prompt Pack Export

A Prompt Pack assembles a curated subset of a project's entities and exports them as a structured generation packet.

- Exports support JSON and prompt/markdown modes.
- The exported packet is intended for direct LLM injection — all sections are always present so consumers never encounter missing keys.
- A frozen `sourcePayloadJSON` snapshot is stored on each `GenerationOutput` for regenerate/continue/remix lineage.

---

## Generation

### Current state

- `GenerationOutput` model is fully defined and stored locally via SwiftData.
- Source payload snapshots (`sourcePayloadJSON`) are preserved at generation time.
- Lineage fields (`generationAction`, `parentGenerationID`) support continue/remix flows.
- `GenerationLengthMode`: `short` (800 tokens) / `medium` (1600) / `long` (3000) / `chapter` (6000).
- Local `GenerationUsageTracker` records usage events for audit purposes.
- `GenerationStatus`: `draft` → `generating` → `complete` / `failed`.
- `OutputVisibility`: `private` / `shared` / `unlisted`.

### Backend generation (planned / in progress)

Backend-backed generation is not yet wired to the iOS app. The intended stack:

- **Supabase Auth** — user identity; JWT passed to Edge Functions
- **Supabase Postgres** — stores `generation_outputs`, `generation_usage_events`, `shared_outputs`, `remix_events`
- **Row Level Security** — all tables protected; users access only their own rows
- **Supabase Edge Functions** (`generate-story`) — calls OpenAI server-side; never exposes keys to the client
- **OpenAI** — called only from Edge Functions; no API key in the iOS app

See [`docs/generate-story-edge-function.md`](docs/generate-story-edge-function.md) for the full Edge Function contract.

---

## Local Development

**Requirements**
- Xcode 15 or later
- iOS 17 simulator or device

**Run the app**

```bash
open CathedralOSApp.xcodeproj
# Press Run in Xcode, or:
xcodebuild build \
  -project CathedralOSApp.xcodeproj \
  -scheme CathedralOSApp \
  -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO
```

**Configure Supabase (optional — required for backend features)**

See [`BACKEND_SETUP.md`](BACKEND_SETUP.md) for full instructions. Summary:

1. Add `SupabaseProjectURL` and `SupabaseAnonKey` to `Info.plist` (or a `.xcconfig` file).
2. Do **not** commit these values to source control.
3. If the keys are absent, the app runs in local-only mode and shows a "Backend not configured" warning in the Account tab.

**Run tests**

```bash
xcodebuild test \
  -project CathedralOSApp.xcodeproj \
  -scheme CathedralOSApp \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,OS=latest,name=iPhone 16" \
  CODE_SIGNING_ALLOWED=NO
```

---

## Testing

The test suite (`CathedralOSAppTests/`) covers:

| Area | Test file(s) |
|---|---|
| Field template engine | `FieldTemplateEngineTests`, `TieredFieldsTests` |
| Schema import/export round-trip | `ProjectSchemaRoundTripTests`, `ImportHardeningTests`, `ImportedEntityEditingTests` |
| Prompt Pack export | `PromptPackExportBuilderTests`, `PromptPackJSONAssemblerTests`, `PromptPackAssemblerTests` |
| Tag-entry behavior | `TagFieldLogicTests` |
| Generation output scaffold | `GenerationOutputTests`, `GenerationOutputActionTests`, `GenerationLengthModeTests` |
| Usage tracking | `GenerationUsageTrackerTests` |
| Literary entities | `LiteraryEntitiesTests` |
| Audience controls | `AudienceControlsTests` |
| Backend configuration | `SupabaseConfigurationTests`, `BackendClientTests`, `AuthServiceTests` |
| Public sharing / remix | `PublicSharingTests`, `RemixFromSharedOutputTests` |
| Other | `AskPackAssemblerTests`, `CompilerTests`, `ExportFormatterTests`, `GenerationServiceTests`, `PrivacySafeTitleTests`, `ProfileSelectionTests`, `PromptPackBuilderTests`, `TemplatesTests` |

---

## Backend Setup

See [`BACKEND_SETUP.md`](BACKEND_SETUP.md) for iOS configuration (Info.plist keys, `.xcconfig` approach, CI injection).

See [`docs/supabase-schema.md`](docs/supabase-schema.md) for the Postgres schema, RLS policies, and migration instructions.

See [`docs/generate-story-edge-function.md`](docs/generate-story-edge-function.md) for the Edge Function contract, secrets, and deployment steps.

### Backend Roadmap

The Supabase backend is partially scaffolded. The following remain to be completed:

- [ ] Wire `GenerationBackendService` to the `generate-story` Edge Function
- [ ] Sync `GenerationOutput` records to `generation_outputs` after generation
- [ ] Implement `UsageSyncService` to push local usage events to `generation_usage_events`
- [ ] Implement `PublicSharingService` backend calls (publish, unpublish, browse)
- [ ] Enforce usage quotas server-side
- [ ] Enable public anonymous browse for `shared_outputs`

---

## Security Notes

- **Never put `OPENAI_API_KEY` in the iOS app**, `.xcconfig`, or any committed file. It lives in Supabase function secrets only.
- **Never commit the Supabase service-role key**. It bypasses all RLS policies.
- The iOS app may use the Supabase **anon key** only. All data access is enforced by RLS policies.
- All private cloud data (generation outputs, usage events, profiles) is protected by RLS. Row-level policies restrict every user to their own rows.
- The `user_id` written to the database is always derived from the verified JWT on the server — never from the request body.

---

## CI

GitHub Actions runs build and unit tests on every pull request and push to `main`. Workflow: `.github/workflows/ios.yml`.

## TestFlight CI/CD Setup

A separate workflow (`.github/workflows/testflight.yml`) builds a signed archive and uploads it to TestFlight. It is triggered manually (`workflow_dispatch`) or automatically on pushes to `main`.

### Required GitHub Secrets

Add these in **Settings → Secrets and variables → Actions → Repository secrets**:

| Secret name | Description |
|---|---|
| `ASC_KEY_ID` | App Store Connect API key ID (e.g. `ABC1234DEF`) |
| `ASC_ISSUER_ID` | App Store Connect issuer UUID |
| `ASC_API_KEY` | **Base64-encoded** contents of the `.p8` API key file |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |
| `APP_IDENTIFIER` | Bundle ID — defaults to `com.savagesbydesign.CathedralOS` |
| `MATCH_GIT_URL` | HTTPS URL of your private Match certificates repository |
| `MATCH_PASSWORD` | Passphrase used to encrypt/decrypt Match assets |
| `MATCH_GIT_TOKEN` | GitHub Personal Access Token (or equivalent) with read access to the Match repo; **write access required during bootstrap** |

**Encode the `.p8` key for `ASC_API_KEY`:**

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n'
```

### Required Apple-side prerequisites

1. **App ID** — Create an explicit App ID for `com.savagesbydesign.CathedralOS` in [Apple Developer portal](https://developer.apple.com/account/resources/identifiers/list) with the capabilities your app uses.
2. **App in App Store Connect** — Create the app record at [appstoreconnect.apple.com](https://appstoreconnect.apple.com) with the same bundle ID.
3. **App Store Connect API key** — Create an API key under **Users and Access → Keys** with the **App Manager** (or **Developer**) role. Download the `.p8` file — it can only be downloaded once.
4. **Match certificates repository** — Create a private GitHub repository to store encrypted signing assets (e.g. `github.com/your-org/ios-certificates`). Set `MATCH_GIT_URL` to its HTTPS URL.
5. **Bootstrap Match** — Run once to generate and store certificates/profiles. No local Mac needed — use the **Bootstrap Signing** GitHub Actions workflow (see [Bootstrap signing from GitHub Actions](#bootstrap-signing-from-github-actions-no-local-mac-required) below).

### First-time setup runbook

1. Complete all Apple-side prerequisites above.
2. Add every secret listed in the table to the GitHub repository.
3. Temporarily ensure `MATCH_GIT_TOKEN` has **write** access to the Match certificates repo.
4. Go to **Actions → Bootstrap Signing → Run workflow** and select the `main` branch to create the distribution cert and provisioning profile.
5. After bootstrap succeeds, go to **Actions → TestFlight Deploy → Run workflow** to verify the full build and upload.
6. (Optional) Downgrade `MATCH_GIT_TOKEN` to read-only access — normal TestFlight runs do not need write access.

### Manually triggering a TestFlight upload

```
GitHub UI:  Actions → TestFlight Deploy → Run workflow → Run workflow
gh CLI:     gh workflow run testflight.yml --ref main
```

### Signing behaviour

The workflow uses [Match](https://docs.fastlane.tools/actions/match/) in `readonly` mode — it downloads existing certificates and profiles from your Match repo; it does **not** generate or overwrite anything during CI. This keeps CI deterministic and non-destructive.

### Bundle identifier

The bundle ID is `com.savagesbydesign.CathedralOS` (set in `CathedralOSApp.xcodeproj`). To change it:

1. Update `PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project (target **Build Settings**).
2. Update the App ID in Apple Developer portal.
3. Re-run the **Bootstrap Signing** workflow (or `fastlane bootstrap_signing` locally) to generate matching provisioning profiles.
4. Update the `APP_IDENTIFIER` GitHub Secret.

## Bootstrap signing from GitHub Actions (no local Mac required)

This is the recommended path when you only have a phone or no macOS machine available. The **Bootstrap Signing** workflow (`bootstrap-signing.yml`) creates the App Store distribution certificate and provisioning profile in the private Match certificates repository entirely from CI.

### When to run Bootstrap Signing

- First time setting up the repository (Match certs repo is empty)
- After rotating or revoking the distribution certificate
- Whenever the `beta` lane fails with `"No code signing identity found"`

### Steps

1. **Ensure all secrets are set** in **Settings → Secrets and variables → Actions → Repository secrets** (see the table above). Pay attention to `APP_IDENTIFIER` — it must be `com.savagesbydesign.CathedralOS`.

2. **Give `MATCH_GIT_TOKEN` write access** to the private Match certificates repository (`CathedralOS-certs` or equivalent). This is only needed during bootstrap; you can downgrade to read-only after.

3. **Run Bootstrap Signing**: go to **Actions → Bootstrap Signing → Run workflow** and click **Run workflow** on the `main` branch. The workflow runs `fastlane bootstrap_signing`, which calls Match with `readonly: false` to generate and push the certificate and profile.

4. **After success, run TestFlight Deploy**: go to **Actions → TestFlight Deploy → Run workflow**. The `beta` lane uses `readonly: true`, so it will download the assets created in step 3 without modifying anything.

> **Security note:** Once bootstrap succeeds you can revoke write access on `MATCH_GIT_TOKEN` or rotate it to a read-only token. Normal TestFlight deploys never need write access to the Match repo.

## Roadmap

- Harden import/export (validation, error messages, edge cases)
- Backend-backed generation via Supabase Edge Functions
- Saved output sync to Supabase Postgres
- Usage controls and quota enforcement
- Public sharing of generated outputs
- Remix from shared outputs
- Pricing / credits (future)
