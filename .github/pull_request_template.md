## PR Type

<!-- Check one -->
- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that breaks existing behavior)
- [ ] Refactor / docs (no behavior change)

## What changed

<!-- Brief description of the change -->

## Pre-submission checklist

### iOS Build verification (REQUIRED)
- [ ] iOS Build for this PR **green on first attempt** (no retries)
- [ ] If iOS Build failed before passing, **scanned the full log for masked errors** — some build errors only surface after the first one is fixed. Don't stop at the first error. See `docs/ios-build-error-catalog.md`.
- [ ] Named arguments in call sites match parameter declaration order (Swift compiler: "argument 'X' must precede argument 'Y'")
- [ ] Action icons HStack inside a NavigationLink has `.fixedSize(horizontal: true, vertical: false)` to prevent title column squeeze
- [ ] NavigationLink wrapping a row that needs drag-to-reorder has `.buttonStyle(.plain)`

### Pre-PR survey (per kevbot-brain #227)
- [ ] Identified the artifact category (service client | view | model | test | migration | doc)
- [ ] For NEW files: recalled memory for that category, found an existing anchor artifact of the same category, mirrored its folder + pbxproj pattern
- [ ] For NEW files: NOT defaulted to `CathedralOSApp/Features/Projects/` — used the canonical category folder (e.g., `Services/` for service clients, `Models/` for SwiftData models)
- [ ] For MODIFIED files: verified the modification doesn't break the existing pattern (especially Swift struct scope — computed properties are member-level, don't cross view boundaries)
- [ ] pbxproj registration (if added new .swift): added in 4 places — PBXFileReference, PBXBuildFile, group children, AND the **MAIN app target's** PBXSourcesBuildPhase (NOT test target)

### Smoke test
- [ ] Tested the actual behavior on real data (not just compile-clean)
- [ ] Verified the fix doesn't regress adjacent features
- [ ] If this PR addresses a carry-over note from a prior PR, confirmed the prior carry-over is resolved

## TestFlight Deploy plan

<!-- e.g. "Manual dispatch after merge — no changes to user-visible behavior" -->

## Carryover (if any)

<!-- Bugs found during smoke test that this PR doesn't address; flag for follow-up PR -->
