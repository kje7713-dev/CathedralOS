# CathedralOS iOS Build Error Catalog

Recurring build errors observed in the iOS pipeline (PR #348, #350-#354 series, 2026-08-17). When a new build error matches one of these signatures, apply the fix pattern below.

## 1. "Build input file cannot be found: CathedralOSApp/Services/<name>.swift"

**Seen in:** PR #350 (CoherenceCheckService)

**Root cause:** New Swift file placed under `Features/Projects/` instead of `Services/`. The pbxproj registers the file in the Services group, but the actual file is elsewhere → xcodebuild reports "Build input file cannot be found".

**Fix pattern:**
1. Move the file to `CathedralOSApp/Services/<name>.swift` (or whatever category folder the file belongs to)
2. No pbxproj change needed — the file's group registration was correct
3. Verify by running iOS Build again

**Pre-PR survey reminder:** Before adding a new .swift file, identify its category and place it in the matching folder. Service clients → `Services/`. SwiftUI views → `Features/<FeatureName>/`. SwiftData models → `Models/`. See kevbot-brain chunk #226.

## 2. "cannot find 'X' in scope" in OutlineSectionsRegionView (or similar)

**Seen in:** PR #351 (CoherenceCheckService scope error)

**Root cause:** Treated a private computed property as free-floating across view boundaries. Swift struct scope is member-level — `OutlineSectionsRegionView.availableBeats` is not visible from `KickoffConfirmationSheet` even though both views reference the same `project`.

**Fix pattern:**
1. Declare the computed property locally inside the consuming view (copy the implementation, don't try to reach across)
2. OR pass the value as a parameter rather than re-deriving it

**Pre-PR survey reminder:** When borrowing logic from another struct, copy the computed property into the consumer rather than reaching across. See kevbot-brain chunk #228.

## 3. "argument 'X' must precede argument 'Y'"

**Seen in:** PR #354 hotfix (commit 12f182c) — "argument 'onEdit' must precede argument 'onGenerate'"

**Root cause:** When using named arguments in a Swift function call, arguments must appear in the same order as the parameter declarations. Adding `onEdit` as the first parameter declaration requires `onEdit` to be the first named argument in the call site.

**Fix pattern:**
1. Move the newly-added named argument to the position matching its parameter declaration order
2. Don't rely on argument labels to "skip" parameters — Swift requires positional order to match

**Pre-PR survey reminder:** When adding a new parameter to a struct/function used at many call sites, check whether the call sites need re-ordering. If you add a parameter, the call site may need to be updated too.

## 4. "Source file not in PHASE" / 11 iOS Build failures from pbxproj registration

**Seen in:** PR #348 (ChapterReaderView) — 11 iOS Build failures

**Root cause:** CathedralOS xcodeproj has TWO Sources build phases — one for the app target, one for the test target. Adding a new .swift file's "in Sources" entry to the WRONG target's phase = xcodebuild silently skips the file. NO warning, NO parse error, just "cannot find X in scope" at the consumer site.

**Fix pattern:**
1. Verify which Sources phase the entry belongs to — main app target's phase (ends ~line 963) vs test target's phase (starts ~line 964)
2. The app target's Sources phase is the FIRST `files = (` block (UUID `000000000000000000000011`). The test target's is the SECOND (UUID `000000000000000000000014`)
3. Move the entry to the correct phase

**Pre-PR survey reminder:** When adding a new .swift file, ALL FOUR pbxproj entries must be added (PBXFileReference, PBXBuildFile, group children, AND the **MAIN app target's** PBXSourcesBuildPhase). Never skip the Sources phase entry — that's the one xcodebuild silently ignores when in the wrong target.

## 5. NavigationLink wrapping a List row → drag gesture dead

**Seen in:** PR #353 (edit + reorder fix)

**Root cause:** `NavigationLink { ... } label: { row }` wraps the row in a button-like container that consumes touch events before the List's drag gesture can recognize them. Result: tap works, drag doesn't.

**Fix pattern:**
1. Add `.buttonStyle(.plain)` to the NavigationLink — frees the List's drag gesture
2. OR use a Button + programmatic navigation instead of NavigationLink

**Pre-PR survey reminder:** When wrapping a row in a NavigationLink AND the row needs drag-to-reorder, add `.buttonStyle(.plain)`. Default button style blocks the drag gesture.

## 6. Action icons HStack wrapped in NavigationLink → title column squeezed

**Seen in:** PR #354 (inline Edit + .fixedSize)

**Root cause:** Action icons HStack is content-sized by default. Inside a NavigationLink, the chevron + button wrapping squeezes the title column to ~30pt and stacks the icons vertically instead of horizontally.

**Fix pattern:**
1. Add `.fixedSize(horizontal: true, vertical: false)` to the action icons HStack
2. This pins the HStack to its intrinsic content width, restoring the title column to ~120pt and bringing icons back to a horizontal row

**Pre-PR survey reminder:** When wrapping an HStack with action icons inside a NavigationLink, use `.fixedSize(horizontal: true, vertical: false)` to prevent the title column from being squeezed.

## 7. `@MainActor` class/method called from non-isolated context — `expression is 'async' but is not marked with 'await'`

**Seen in:** PR #383 (and the lead-up to it on 2026-08-19 with `BeatDeleteDiagnostics`)

**Root cause:** Marking a singleton or helper as `@MainActor` makes all its methods MainActor-isolated. Calling those methods from a URLSession callback, non-MainActor Task, or any non-isolated async context produces the compile error `expression is 'async' but is not marked with 'await'`. Easy to hit if you want a thread-safe shared state but don't think about every call site in advance.

**Fix pattern (choose one):**
1. **Drop `@MainActor`, use NSLock.** If the singleton needs to be called from any context, remove the `@MainActor` annotation and use an explicit lock for thread safety. Example: `private let lock = NSLock(); private var _lines: [String]; var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }; func append(_ line: String) { lock.lock(); _lines.append(line); lock.unlock() }`. Best for: pure data containers, loggers, diagnostic buffers.
2. **Make it an `actor`.** Use Swift's `actor` keyword for thread-safe state with async isolation. All access becomes `await` — forces call sites to think about isolation. Best for: state that has its own async operations.
3. **Pass the modelContext/dependency into the call site.** If the call site is on MainActor (e.g., a SwiftUI View body), get the dependency there and pass it down — don't put `@MainActor` on a service that the call site can't satisfy. Best for: View-driven services.

**Pre-PR survey reminder:** Before marking a new class as `@MainActor`, grep for all its call sites and verify each is on MainActor. If any call site is in a URLSession callback, non-MainActor Task, or any async-non-isolated context, use option 1 (drop + NSLock) instead.

## 8. SwiftData `@Relationship` cache is SHARED — child rows appear "stale" after delete

**Seen in:** PR #383 (beat-resurrection bug, Codex's fix)

**Root cause:** SwiftData's `@Relationship` collections are cached in memory and SHARED across all references to the same entity. After `modelContext.delete(child)` + `modelContext.save()`, the parent's `parent.children` collection can STILL contain the deleted child if the in-memory cache wasn't refreshed. Any sync/edge function that reads `parent.children` (e.g., `arc.beats`, `parent.attachments`) will re-push the deleted child via UPSERT, resurrecting it on the server.

**Failed fix attempts:**
- `try? modelContext.refresh(parent)` — does not exist on SwiftData `ModelContext` (it's a Core Data API on `NSManagedObjectContext`). Compile error: `value of type 'ModelContext' has no member 'refresh'`.
- `FetchDescriptor<Parent>(predicate: #Predicate { $0.id == parentID })` re-fetch — the fresh parent still shares the SAME @Relationship cache for its children. The deleted child is still there. Bug not fixed.
- Pass `ModelContext` into the sync function and try to refresh — same cache, same problem.

**Fix pattern (the only one that works):**
Fetch the CHILD rows directly, not the parent. Don't traverse the relationship at all:
```swift
let childDescriptor = FetchDescriptor<ChildType>(
    predicate: #Predicate<ChildType> { child in
        child.parent?.id == parentID
    },
    sortBy: [SortDescriptor(\.position)]
)
let freshChildren = try modelContext.fetch(childDescriptor)
```
Now `freshChildren` is a brand-new collection that bypasses the parent's @Relationship cache. Use `freshChildren` (not `parent.children`) for any sync/edge function payload.

**Pre-PR survey reminder:** Any sync/edge function that reads `entity.beats` / `entity.children` / `entity.attachments` should fetch the child type directly via `FetchDescriptor<ChildType>`, NOT traverse the relationship. This is a class of bug, not a one-off. Apply proactively to all sync/edge functions that read relationship collections.

## ## Masked error detection

Some build errors mask others — the next error only surfaces after the first is fixed:
- File location error masked the scope error (PR #350 → PR #351)
- Scope error would have masked... (didn't happen because PR #351 fixed scope)
- Argument ordering might mask... (didn't happen because hotfix was clean)

**When fixing one iOS Build error, ALWAYS scan the full log for other errors.** Don't stop at the first error. Specifically search the build log for:
- `error:` (any)
- `cannot find` (any)
- `argument` (named-arg ordering)
- `must precede` (named-arg ordering)

## Pattern: each PR has a different kind of build error

PR #348 → pbxproj Sources phase (11 builds)
PR #350 → file location (1 build)
PR #351 → Swift struct scope (1 build, masked by #350's error)
PR #352 → success (scope fix)
PR #353 → NavigationLink drag gesture (needed `.buttonStyle(.plain)`)
PR #354 → argument ordering (needed hotfix)
PR #354 hotfix → success

The pattern is clear: no single error pattern dominates; each PR can surface a NEW kind of error. The systematic review (`.github/pull_request_template.md` + this catalog + kevbot-brain #227) is the defense.
