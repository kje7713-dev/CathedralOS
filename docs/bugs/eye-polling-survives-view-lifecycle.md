# CathedralOS eye polling cancelled by view lifecycle

## Symptom

After PR #341/#342/#343 (squashes `75f805d`, `d256d56`, `b96053d`), the 9-PR chain
was claimed closed: `@Published outputRefreshRevision` on
`DataDurabilityCoordinator`, `Task.detached` polling inner block,
`refreshAllOutputs()` after every sync, `EyeDebugStore.shared.record(...)`. All
four layers wired.

In practice (Kevin's diagnostics at 2026-08-16 09:31 EDT on TestFlight build
`20260816131251`):

- Credits `26 -> 25` (one generation kicked off)
- Cloud outputs `95 -> 96` (new output persisted server-side)
- **Local outputs stays at `94`** (new output never reached the iOS store)
- **`--- Eye Debug (latest) ---` section absent** (no `record()` call fired)
- Last Sync Probe timestamp: `Aug 16, 9:18 AM` (14 minutes *before* the
  generation — the most recent sync was the Account -> "Sync Everything" path,
  not the polling path)

Translation: the polling-driven sync never ran. The detached inner block never
executed.

## Root cause

PR #341 detached the *inner* block inside the polling loop:

```swift
// OutlineSectionsRegionView.swift ~line 581
@State private var pollingTask: Task<Void, Never>?
...
pollingTask = Task {                          // <-- (A) outer loop, NOT detached
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        do {
            let status = try await runOutlineService.status(runID: runID)
            activeRunStatus = status
            if status.status == "completed" || status.status == "failed" {
                Task.detached(priority: .userInitiated) { @MainActor in  // <-- (B) PR #341 fix
                    _ = await DataDurabilityCoordinator.shared.performManualSyncAll(context: modelContext)
                    refreshAllOutputs()
                    ...
                    EyeDebugStore.shared.record(...)
                }
                break
            }
        } catch { /* keep polling */ }
    }
}
```

(A) is the outer polling loop. It is a *child* of the view's `@State` for
`pollingTask`. When the user navigates away from the project view (e.g., taps
Account -> Diagnostics while a run is in flight), the view is destroyed,
`pollingTask`'s `@State` storage is released, and the outer Task is cancelled
before reaching the `status == "completed"` branch.

(B) is the inner `Task.detached` block. PR #341 made this detached so it would
survive view destruction — *if* it ever runs. But (A) is what creates (B). If
(A) is cancelled first, (B) is never created.

So PR #341 fixed the wrong layer: it protected the inner block from view
destruction, but the outer block — the one that actually schedules the inner
block — was still tied to the view's lifecycle.

## Reproduce

1. Open any project on TestFlight build `20260816131251+`.
2. Kick off a generation on any section.
3. Immediately tap Account -> Diagnostics (or any tab that destroys the project
   view).
4. Wait for the generation to complete on the server (cloud count increases).
5. Return to the project view.
6. Eye button does not appear. Local output count did not increase.
7. Copy Diagnostics text -> no `--- Eye Debug (latest) ---` section.

## Fix

Move the polling loop into `DataDurabilityCoordinator` (singleton). Make the
*outer* `Task` detached from the start, not just the inner block.

```swift
// DataDurabilityCoordinator.swift (new)

@Published private(set) var activeRunStatus: RunOutlineStatus?
private var pollingTask: Task<Void, Never>?

func startPolling(
    runID: String,
    runOutlineService: RunOutlineService,
    context: ModelContext,
    onSyncCompleted: @escaping @MainActor (ModelContext) -> Void
) {
    pollingTask?.cancel()
    activeRunStatus = nil

    let coordinator = self
    pollingTask = Task.detached(priority: .userInitiated) { @MainActor in
        let service = runOutlineService
        let modelContext = context
        let callback = onSyncCompleted

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            do {
                let status = try await service.status(runID: runID)
                coordinator.activeRunStatus = status
                if status.status == "completed" || status.status == "failed" {
                    DiagnosticLog.write("poll: run finished (\(status.status)); triggering syncAll")
                    _ = await coordinator.performManualSyncAll(context: modelContext)
                    DiagnosticLog.write("poll: syncAll complete")
                    callback(modelContext)
                    coordinator.pollingTask = nil
                    break
                }
            } catch {
                // keep polling on transient errors
            }
        }
    }
}

func stopPolling() {
    pollingTask?.cancel()
    pollingTask = nil
    activeRunStatus = nil
}
```

The view drops both `@State private var activeRunStatus` and `@State private var
pollingTask`. It observes `durabilityCoordinator.activeRunStatus` (already
in scope as `@ObservedObject` since PR #338) and calls
`durabilityCoordinator.startPolling(...)` from `kickoffAndStartPolling`.

The `onSyncCompleted` callback captures the existing eye-debug + refresh logic
verbatim (moved out of the inner detached block, now invoked from the
coordinator's polling Task).

## Why this is the structural fix (not another workaround)

- Polling lives on a long-lived singleton. View destruction does not cancel
  it.
- The captured `modelContext` is held by strong reference in the closure —
  it outlives the view's `@Environment(\.modelContext)` because the
  SwiftData `ModelContext` reference is to the underlying container which
  persists across views.
- `performManualSyncAll` already increments `outputRefreshRevision` (PR #343)
  and posts the generation-outputs-changed notification (PR #342). The view's
  existing `.onChange(of: outputRefreshRevision)` and `.onReceive(...)` hooks
  fire normally — the view re-renders when it re-appears, regardless of
  whether it was visible during the polling.
- A new `startPolling(...)` call cancels the previous polling Task (same as
  the old view-side behavior). `stopPolling()` exists for symmetry but is not
  called from `onDisappear` — the polling continues until completion.

## What this PR does NOT fix

1. **StoreKit products loaded: 0** — App Store Connect config issue (carryover
   since #335). Not a code issue.
2. **H-case detection in the eye-debug snapshot** — the existing pattern
   refreshes `allOutputs` *before* recording the snapshot, so the snapshot
   always shows `queryCount == fetchCount`. Out of scope for this fix.
3. **Race between run-outline status returning "completed" and the new
   `generation_outputs` row actually being persisted in cloud** — if the
   coordinator's sync runs before the row is durable, the new output still
   won't reach local. Possible follow-up: poll one more time after
   "completed" status before running `performManualSyncAll`. Out of scope
   here; flagging for the next PR if Kevin reproduces.

## Acceptance criteria

- Generate one section, immediately navigate to Diagnostics, wait for the run
  to complete, return to the project view -> **eye button appears within one
  render after returning**.
- Diagnostics text after the generation includes the
  `--- Eye Debug (latest) ---` section (proves the polling Task ran to
  completion).
- Manual sync (Account -> "Sync Everything") still works.
- Two consecutive generations on different sections both result in eye buttons
  appearing (no leaked polling Task from the first run blocking the second).
