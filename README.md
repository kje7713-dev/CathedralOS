# CathedralOS

[![iOS CI](https://github.com/kje7713-dev/CathedralOS/actions/workflows/ios.yml/badge.svg?branch=main)](https://github.com/kje7713-dev/CathedralOS/actions/workflows/ios.yml)

CathedralOS helps AI understand what matters to you before it answers.

## What It Does

LLMs give generic advice when they lack context. CathedralOS stores your current goals and constraints locally, then compiles them into a small, structured block you can paste into any LLM.

- **Goals** — what you are trying to achieve
- **Constraints** — what limits you
- **Compiler** — produces a deterministic, paste-ready context block

V1 is goals + constraints + compiler. Nothing else.

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
    "goals": [
      "Improve household organization",
      "Reach $5k MRR in 3-6 months"
    ],
    "instruction_bias": [
      "Prefer short actions with fast feedback.",
      "Respect constraints and avoid requiring long uninterrupted blocks."
    ]
  }
}
```

### Instructions Mode

Plain-text format optimized for direct pasting into an LLM system prompt. Example:

```
Use the following goals and constraints as ground truth when answering.
Optimize your answer within these limits.

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

## Roadmap

- Multiple Cathedral profiles
- Redaction / abstraction rules
- Compile templates
- Snapshot history
