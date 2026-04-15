# CathedralOS

[![iOS CI](https://github.com/kje7713-dev/CathedralOS/actions/workflows/ios.yml/badge.svg?branch=main)](https://github.com/kje7713-dev/CathedralOS/actions/workflows/ios.yml)

CathedralOS helps AI understand what matters to you before it answers.

## What It Does

LLMs give generic advice when they lack context. CathedralOS stores your roles, domains, goals, and constraints locally, then compiles them into a small, structured block you can paste into any LLM.

- **Roles** — who you are (e.g. founder, parent, engineer)
- **Domains** — areas of your life or work you care about
- **Goals** — what you are trying to achieve
- **Constraints** — what limits you
- **Compiler** — produces a deterministic, paste-ready context block

## How to Use

1. Add your goals and constraints in the app.
2. Choose an export format (JSON or Instructions).
3. Copy or share the compiled block, then paste it into any LLM.

## Export Formats

### JSON Mode

Structured output, sorted keys, valid JSON. Example:

```json
{
  "cathedral_context": {
    "constraints": [
      "Time and focus stretched thin"
    ],
    "domains": [
      "Business",
      "Home"
    ],
    "goals": [
      "Improve household organization",
      "Reach $5k MRR in 3-6 months"
    ],
    "instruction_bias": [
      "Prefer short actions with fast feedback.",
      "Respect constraints and avoid requiring long uninterrupted blocks."
    ],
    "roles": [
      "Founder",
      "Parent"
    ]
  }
}
```

### Instructions Mode

Plain-text format optimized for direct pasting into an LLM system prompt. Example:

```
Use the following goals and constraints as ground truth when answering.
Optimize your answer within these limits.

ROLES:
- Founder
- Parent

DOMAINS:
- Business
- Home

GOALS:
- Improve household organization
- Reach $5k MRR in 3-6 months

CONSTRAINTS:
- Time and focus stretched thin

ANSWERING RULES:
- Prefer short actions with fast feedback.
- Respect constraints and avoid requiring long uninterrupted blocks.
```

## Privacy

CathedralOS is local-first. No backend for MVP.

- Raw context stays on device.
- Only the compiled block is copied or shared.
- No analytics that inspect personal context.

## Development

**Requirements**

- Xcode 15 or later
- iOS 17 simulator or device

**Run locally**

Open `CathedralOSApp.xcodeproj` in Xcode and press **Run**.

**Run tests**

```bash
xcodebuild test \
  -project CathedralOSApp.xcodeproj \
  -scheme CathedralOSApp \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,OS=latest,name=iPhone 16" \
  CODE_SIGNING_ALLOWED=NO
```

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

- Multiple Cathedral profiles
- Redaction / abstraction rules
- Compile templates
- Snapshot history
