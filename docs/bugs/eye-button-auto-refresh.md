# CathedralOS eye button doesn't auto-refresh after generation

## Symptom

In `OutlineSectionsRegionView`, each `OutlineSectionRow` shows an **eye button** (line ~621) when `outputsBySection[section.id]` is non-empty. After a new generation completes in cloud, the eye button **does not appear automatically** for the section that was just generated. It only appears after:

1. **Manual sync** — `Account → Diagnostics → "Sync All Outputs"` button (which calls `durabilityCoordinator.performOutputSync(context:)`)
2. **Leaving the app and re-entering** — kills the view, re-attaches it, fires `.task`

Both manual sync and re-entry work because they re-trigger `refreshAllOutputs()` via `.task` on view (re-)appear. The **polling-driven path doesn't work** — the polling inner Task's `refreshAllOutputs()` is not propagating to the view.

## What was tried (8 PRs, all squashed on main)

| PR | squash | Approach | Why it failed |
|---|---|---|---|
| #334 | `883b639` | direct `pullOutputs` from polling | bypasses `DataDurabilityCoordinator.runOperation`, no `@Published` flips |
| #335 | `303ec09` | `MainActor.run` wrap inside `pullOutputs` | Swift 5 already inherits MainActor; no-op |
| #337 | `29d7f23` | polling → `performManualSyncAll` | `@Published` flips fire but view doesn't observe coordinator |
| #338 | `2b63212` | `@ObservedObject DataDurabilityCoordinator` in view | view now observes, but eye button still missing |
| #339 | `02850c1` | `DiagnosticLog.write` eye-debug block | log file inaccessible on TestFlight (`UIFileSharingEnabled=NO`) |
| #340 | `fa01b91` | surface eye-debug in copyable Diagnostics text | (data path fix only) |
| #341 | `75f805d` | bypass `@Query` with `@State` + `Task.detached` inner Task | `@State` storage release issue — `Task.detached` captures `self` and `@State` backing storage can be released before the Task completes; assignment becomes a silent no-op |
| #342 | `d256d56` | `NotificationCenter` to decouple refresh from view lifecycle | **STILL BROKEN** — eye button still doesn't appear automatically |

## Critical diagnostic from Kevin (12:55 EDT)

> "It appears after syncing or leaving the app and going back in. Otherwise don't show."

This is the most important data point. It tells us:

- ✅ `refreshAllOutputs()` works (manual sync + re-entry both work, both call `.task` → `refreshAllOutputs`)
- ❌ Polling-driven `refreshAllOutputs()` is racing with view lifecycle — the assignment to `@State allOutputs` is sometimes a silent no-op

## Key code paths

- **View:** `CathedralOSApp/Features/Projects/OutlineSectionsRegionView.swift`
  - `@State private var allOutputs: [GenerationOutput] = []` (line ~83, PR #341)
  - `private func refreshAllOutputs()` (line ~88) — fetches via `modelContext.fetch(FetchDescriptor<GenerationOutput>(...))`, assigns to `allOutputs`
  - `.task { ... refreshAllOutputs() }` (view body) — fires on view appear/re-appear
  - `.onReceive(NotificationCenter.default.publisher(for: .cathedralOSGenerationOutputsChanged)) { _ in refreshAllOutputs() }` (PR #342) — should fire on every sync
  - Polling Task inner code (PR #341 + #342): `Task.detached(priority: .userInitiated) { @MainActor in ... await performManualSyncAll(...); refreshAllOutputs(); ... }`
  - `outputsBySection` computed property reads `allOutputs` and filters by non-nil `outlineSectionID`

- **Sync coordinator:** `CathedralOSApp/Services/DataDurabilityCoordinator.swift`
  - `runOperation(...)` posts `NotificationCenter.default.post(name: .cathedralOSGenerationOutputsChanged, object: nil)` after inner sync Task completes (PR #342)

## What to investigate (in priority order)

1. **Is the polling Task actually running in PR #342?** Kevin's current TestFlight build should have the NotificationCenter code. Ask Kevin to:
   - Generate a fresh section output
   - Wait 60+ seconds (don't navigate away)
   - Paste a fresh `=== CathedralOS Diagnostics ===` dump
   - The `--- Eye Debug (latest) ---` section (added in PR #340, present in build 2026081316xxxx+) is the smoking gun:

   | Eye Debug signal | Diagnosis |
   |---|---|
   | section missing entirely | Polling Task never reached `performManualSyncAll` |
   | `queryCount=0, fetchCount=N` | `refreshAllOutputs()` didn't fire (the `@State` release issue persists even with NotificationCenter) |
   | `queryCount=N, fetchCount=N, same IDs` | `refreshAllOutputs()` worked but eye button condition is wrong (UUID mismatch in `outputsBySection`) |
   | `queryCount=N, fetchCount=0` | Sync didn't pull (cloud/local desync) |

2. **If the polling Task ISN'T running**, the bug is in the polling Task lifecycle. Possibilities:
   - `pollingTask?.cancel()` is called when Kevin generates a new run, but the previous detached inner Task is still running. Two inner Tasks both call `performManualSyncAll` concurrently, racing.
   - The detached Task captures `self` and the view's `@State` storage is released before the Task completes. Even with NotificationCenter, the view's `.onReceive` subscription is gone.
   - The `Task.detached` priority is wrong, or the task is being scheduled but never executed.

3. **If the polling Task IS running but the notification isn't firing** (or the .onReceive isn't catching it), the bug is in:
   - NotificationCenter post — wrong thread, wrong name, observer not subscribed
   - SwiftUI view lifecycle — the view is being deallocated before the notification fires

4. **If the polling Task is running, the notification fires, refreshAllOutputs is called, but the eye button still doesn't appear**, the bug is in:
   - `modelContext.fetch(descriptor:)` returning stale data (autosave issue, or different context)
   - `outputsBySection` computed property not capturing the new row (UUID mismatch)
   - The eye button condition `if !outputs.isEmpty, let onTapOutput { ... }` (line ~621) being wrong

## Likely root cause (my hypothesis, may be wrong)

The `Task.detached` inner Task captures `self` (the view struct). When Kevin navigates away, the view's `@State` storage is released but the Task continues. Even with the NotificationCenter fix in PR #342, the issue is that the **view's `.onReceive` subscription is tied to the view's lifecycle** — when the view is deallocated, the subscription is gone. So if the polling Task fires while the view is deallocated (which happens because Kevin's eye button is on the project view, and the project view is part of a tab that can be switched away), the notification is posted but no one listens.

The fix would be: **post the notification AND cache the latest outputs in a long-lived singleton** (like `EyeDebugStore` already does for the eye-debug snapshot). The view reads from the singleton on appear AND the NotificationCenter triggers the singleton's update. This way, even if the view is deallocated when the notification fires, the singleton has the data, and when the view re-appears, the `.task` reads from the singleton.

## Constraints (from Codex prompt + MEMORY.md)

- **Do NOT lead with another `objectWillchange`, `@ObservedObject`, or generic refresh workaround.** Establish exactly which layer is stale first, then propose the smallest durable fix.
- **Do NOT propose another speculative fix until the Eye Debug section data is in.** Ask Kevin for the fresh Diagnostics dump first.
- `MEMORY.md` end-of-PR compaction is in effect — at PR close, store kevbot-brain chunk + append to `memory/YYYY-MM-DD.md`.

## Carryover (NOT the eye button bug)

- 🟡 `StoreKit products loaded: 0` with 4 IDs configured — App Store Connect config issue, independent of code. Mention it but don't fix it.

## Codebase location

- Repo: `/home/kevbot/code/CathedralOS` (working tree clean as of 13:09 EDT, main branch at `d256d56`)
- Key files:
  - `CathedralOSApp/Features/Projects/OutlineSectionsRegionView.swift`
  - `CathedralOSApp/Services/DataDurabilityCoordinator.swift`
  - `CathedralOSApp/Services/GenerationOutputSyncService.swift`
  - `CathedralOSApp/Services/DiagnosticsViewModel.swift` (for the copyable diagnostics text)
- Spec doc: `docs/novel-building.md` (Phase 0/1 architecture — not the bug, but background on `OutlineSectionsRegionView`)
- TestFlight build on Kevin's device: `2026081317xxxx` (PR #342 build)

## Workflow

1. Read `OutlineSectionsRegionView.swift` end-to-end (especially lines ~80-100 for the @State + refreshAllOutputs, ~540-580 for the polling Task structure, and the `.onReceive` observer in the body)
2. Read `DataDurabilityCoordinator.swift` lines ~240-280 for the `runOperation` + notification post
3. Identify which of the four Eye Debug signal patterns matches (or if Eye Debug is missing)
4. If polling Task isn't running: fix the lifecycle (likely a long-lived singleton for the latest outputs)
5. If polling Task IS running but notification isn't firing: fix the notification setup
6. If polling Task IS running and notification fires but eye button doesn't appear: fix the refresh path
7. Write the smallest durable fix as a new PR (suggest name: `fix/ios-eye-button-reliable-refresh`)
8. Report back with: (a) which Eye Debug signal you saw, (b) which layer was actually broken, (c) the fix shipped as a new PR

## Don't break the existing 8 PRs

- Keep the `@State` + `refreshAllOutputs` + `NotificationCenter` structure (PR #341 + #342)
- Keep the `EyeDebugStore` + `--- Eye Debug (latest) ---` copyable text (PR #340)
- Keep the `poll: run finished` / `poll: triggering syncAll` / `poll: syncAll complete` log lines (PR #339)
- The fix should be additive, not a rewrite
