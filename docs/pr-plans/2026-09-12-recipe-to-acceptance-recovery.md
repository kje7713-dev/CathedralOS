## PR 1 — Explicit recipe selection for Suggest Sections  
Work in kje7713-dev/CathedralOS. Start from the latest main and read AGENTS.md.  
This is one narrowly scoped PR. Create a branch, implement the change, run relevant tests, commit, push, and open a PR. Do not deploy anything.  
## Problem  
OutlineSectionsRegionView currently uses project.promptPacks.first in the Suggest Sections/recovery path.  
A project can contain multiple PromptPack recipes, so relationship ordering must not determine which recipe is sent to outline-from-recipe.  
## Required change  
Remove implicit .first recipe selection from the Outline suggestion workflow.  
Implement an explicit recipe selection for Suggest Sections:  
* If the project has zero recipes, Suggest Sections remains unavailable.  
* If it has exactly one recipe, select it automatically.  
* If it has multiple recipes, require the user to choose one before Suggest Sections can run.  
* Persist the selected recipe ID locally per canonical project lineage so ordinary view recreation does not randomly change the selection.  
* If the selected recipe is deleted, clear the stored selection.  
* loadSuggestions, suggestion readiness, recoverable-suggestion handling, and the review sheet source recipe must all use the exact same selected recipe.  
* Never fall back to promptPacks.first when multiple recipes exist.  
Do not modify:  
* outline-from-recipe prompts  
* billing  
* Accept All  
* recipe schema  
* Story Arc behavior  
* cloud migrations  
## Tests  
Add focused tests around recipe resolution:  
1. one recipe auto-resolves;  
2. two recipes never resolve implicitly;  
3. an explicit selected ID resolves the correct recipe;  
4. deleted/missing selected ID fails closed.  
PR title:  
```
fix(outline): make suggestion recipe selection explicit

```
## PR 2 — Reject unresolved recipe selections before planning  
Start from latest main after PR 1 is merged. Read AGENTS.md.  
One PR only. Create branch, implement, test, commit, push, and open the PR. No deployment.  
## Problem  
PromptPackExportBuilder claims to produce the exact selected recipe, but selected characters, relationships, themes and motifs are built with filters against currently existing project entities. Story spark and aftertaste similarly become nil when their stored selected IDs no longer resolve.  
That means a recipe can claim to contain selected material while the actual planning payload silently omits it.  
A paid outline request must not proceed with silently degraded recipe input.  
## Required change  
Add a recipe-selection integrity validator used by the Suggest Sections path before constructing/submitting the request.  
Validate:  
* every selectedCharacterID  
* selectedStorySparkID  
* selectedAftertasteID  
* every selectedRelationshipID  
* every selectedThemeQuestionID  
* every selectedMotifID  
Every selected ID must resolve to exactly one entity belonging to that project.  
If anything is unresolved:  
* do not call the edge function;  
* do not consume credits;  
* surface a clear app error stating that the recipe references deleted/missing material and must be edited.  
Do not silently prune the selection. Do not automatically mutate the recipe. Do not redesign PromptPackExportPayload.  
Keep PromptPackExportBuilder deterministic.  
## Tests  
Add cases proving:  
* fully valid selections pass;  
* each entity class fails when its selected ID is missing;  
* no request is produced from a malformed selection set.  
PR title:  
```
fix(recipe): reject unresolved planning selections

```
## PR 3 — Keep Outline linked to its Story Arc  
Start from latest main. Read AGENTS.md.  
One PR only. Create branch, implement, test, commit, push, open PR. No deployment.  
## Problem  
Outline has storyArcID, and the cloud schema persists it, but normal Story Arc selection does not populate it.  
Outline.storyArcID initializes nil. Current assignments are primarily import/restore paths. StoryArcRegionView.applyTemplate creates/updates the StoryArc without ensuring the project’s Outline points to that arc.  
This leaves the durable ownership graph incomplete.  
## Required change  
Maintain the invariant:  
If a project has a current StoryArc and current Outline, outline.storyArcID == storyArc.id.  
Update only the local planning lifecycle necessary to establish this invariant.  
Cover both orderings:  
1. Story Arc exists before Outline is auto-created.  
2. Outline exists before a Story Arc/template is selected.  
When ensureOutline() creates an outline, initialize storyArcID from the project’s current arc when present.  
When a StoryArc is created/selected in StoryArcRegionView, update the current Outline’s storyArcID.  
Do not create multiple Outlines or StoryArcs.  
Do not touch Accept All, server ownership validation, or planning prompts in this PR.  
## Tests  
Prove:  
* arc first → outline later links correctly;  
* outline first → arc later links correctly;  
* snapshot serialization contains the linked storyArcID;  
* restore preserves the link.  
PR title:  
```
fix(outline): persist story arc linkage

```
## PR 4 — Send and validate canonical planning identity  
Start from latest main after PR 3. Read AGENTS.md.  
One contract-focused PR. Create branch, implement, test, commit, push, open PR. No deployment.  
## Problem  
The server’s OutlineFromRecipeRequest supports outline_id and requestedFormat, but the iOS OutlineSuggestionRequest does not send them.  
Consequences include:  
* persistEnrichmentProvenance() returning immediately because outline_id is missing;  
* no durable association between a planning run and the specific Outline;  
* planning format being implicit;  
* project identity still leaning on mutable/local UUID identity.  
## Required change  
Extend the Suggest Sections request contract with:  
* outline_id  
* project_lineage_id  
* explicit requestedFormat  
For the existing novel workflow, send requestedFormat = "novel" explicitly.  
OutlineSectionsRegionView/OutlineSuggestionService.makeRequest must provide:  
* current Outline ID;  
* project.stableLineageID;  
* current local project ID through the existing recipe payload.  
Before creating a new suggestion run, outline-from-recipe must verify that:  
* outline_id belongs to the authenticated user;  
* the Outline belongs to the supplied project identity;  
* its canonical lineage matches project_lineage_id.  
Do this before any billable LLM call.  
Add project_lineage_id to outline_suggestion_runs with a forward migration and populate it for new runs.  
Do not modify allocation, recovery behavior, story-material prompts, or Accept All in this PR.  
## Tests  
Cover:  
* valid user/project/outline/lineage;  
* another user’s outline ID;  
* correct user but wrong project;  
* correct local project but wrong lineage;  
* request encoding from Swift;  
* enrichment provenance actually persists when a valid outline ID is supplied.  
PR title:  
```
fix(outline): bind suggestion runs to canonical outline identity

```
## PR 5 — Remove existing-section double subtraction  
Start from latest main. Read AGENTS.md.  
One server-planning bug only. Create branch, implement, run focused Deno tests, commit, push, open PR. No deployment.  
## Problem  
buildAllocationPrompt() gives the planner existingSections and explicitly tells it:  
“A beat sufficiently covered by existing sections may use minSections 0.”  
Therefore returned minSections already represents the residual/additional coverage needed.  
Immediately afterward the code calls adjustAllocationForExistingSections, which subtracts the existing-section count again.  
Existing coverage is therefore counted twice.  
## Required change  
Establish one unambiguous semantic:  
Allocation.minSections returned by the allocation planner means the number of NEW sections still required after considering existingSections.  
Under that contract:  
* remove the second subtraction from the production planning path;  
* either remove adjustAllocationForExistingSections if no longer required, or change it so it does not subtract already-accounted-for coverage;  
* update misleading tests/comments.  
Do not change:  
* allocation prompt quality beyond wording needed to make this contract explicit;  
* target novel length;  
* container ranges;  
* expansion logic;  
* recipe obligations.  
## Regression tests  
Include:  
* no existing sections;  
* one existing section where planner returns 0 → remains 0;  
* two existing sections where planner returns 3 additional → remains 3, not 1;  
* mixed beats with different existing coverage.  
PR title:  
```
fix(outline): count existing section coverage once

```
## PR 6 — Recover only the exact current suggestion request  
Start from latest main after PRs 1, 4 and 5. Read AGENTS.md.  
One recovery-identity PR. Create branch, implement, test, commit, push, open PR. No deployment.  
## Problem  
loadRecoverableSuggestions() currently asks for the latest completed run for a project and only verifies project ID and PromptPack ID.  
That can surface stale suggestions after:  
* editing a recipe while keeping its UUID;  
* changing Story Arc beats;  
* changing existing outline sections;  
* changing other request inputs.  
The service already has deterministic request idempotency and a findRun(...idempotencyKey:) path.  
## Required change  
Stop using “latest completed project run” as the authority for Resume Suggestions.  
When the Outline view loads:  
1. resolve the explicitly selected recipe;  
2. build the current OutlineSuggestionRequest using the current recipe, arc, Outline, existing sections, format and canonical lineage;  
3. derive its current idempotency key;  
4. recover only a completed run whose idempotency key matches that exact request.  
Also move durable suggestion-run client identity from local project UUID to canonical stableLineageID.  
Persist both local project ID and lineage where useful, but lineage owns resume-state identity.  
Support decoding existing persisted local suggestion metadata safely, but do not surface mismatched old suggestions as current.  
Do not modify planner behavior, billing, or Accept All.  
## Tests  
Prove:  
* exact same request resumes;  
* recipe content changes under same PromptPack UUID → does not resume;  
* arc beat changes → does not resume;  
* existing section contract changes → does not resume;  
* local project ID drift with unchanged canonical lineage can resume an active run by run ID;  
* a different lineage cannot.  
PR title:  
```
fix(outline): recover suggestions by exact planning identity

```
## PR 7 — Make outline rate limiting real and idempotency-safe  
Start from latest main. Read AGENTS.md.  
One backend operational PR. Create branch, implement, Deno test, commit, push, open PR. No deployment.  
## Problem  
outline-from-recipe checks generation_request_logs for action outline-from-recipe.  
A logRequest() helper exists, but current production code does not call it.  
The check also occurs before the existing idempotent run is resolved, so simply enabling logging could cause reconnects/retries to consume or hit the rate limit.  
## Required change  
Reorder POST handling:  
1. authenticate and validate structural request;  
2. calculate logical suggestion identity/fingerprint;  
3. resolve an existing matching idempotent run first;  
4. if a matching run already exists, return/reconnect to it without consuming a new rate-limit slot;  
5. only a genuinely new logical suggestion request goes through checkRateLimit;  
6. when admitted, record exactly one outline-from-recipe request-log entry.  
Do not double-log worker retries or app reconnect polling.  
Preserve current 5/minute and 30/hour limits unless tests show the constants differ from documentation.  
Do not modify credit billing or planner behavior.  
## Tests  
Prove:  
* new requests produce a log entry;  
* limits count those entries;  
* duplicate same-request POST does not create another entry;  
* reconnect to existing run is not blocked by the rate limiter;  
* different logical request does consume another slot.  
PR title:  
```
fix(outline): enforce idempotency-safe planning rate limits

```
## PR 8 — Correct the story-material repair fallback  
Start from latest main. Read AGENTS.md.  
One outline-from-recipe repair-path PR only. Create branch, implement, Deno test, commit, push, open PR. No deployment.  
This is not a historical-data recovery project.  
## Problem  
recipeMaterialHandles() defines canonical recipe references such as:  
* project.summary  
* character:<id>  
* relationship:<id>  
* theme:<id>  
* motif:<id>  
* storySpark  
* aftertaste  
repairStoryMaterialFromRecipe() currently creates incompatible references such as selectedCharacters[...] / selectedRelationships[...].  
It also treats canonical single-object selectedStorySpark and selectedAftertaste fields as arrays.  
The repaired object then proceeds without being run through the same full validation/sufficiency gate as normal material, and the repair is not consistently persisted back to the run/audit columns.  
## Required change  
Make recipeMaterialHandles() the single authority for recipe-backed references.  
Repair must:  
* use exact canonical handles;  
* correctly consume object-or-null spark and aftertaste fields;  
* preserve project.summary;  
* produce sensible labels/descriptions from actual canonical recipe fields;  
* run validateStoryMaterialEnrichment() on the repaired value;  
* run storyMaterialSufficiency() before continuing;  
* fail closed if repair still cannot satisfy the contract;  
* persist repaired story_material;  
* persist the existing repair audit fields, not merely diagnostic camelCase text.  
Do not invoke an LLM for this repair. Do not alter fresh-enrichment prompting.  
Use realistic canonical PromptPackExportPayload fixtures in tests.  
PR title:  
```
fix(outline): repair story material with canonical recipe handles

```
## PR 9 — Enforce recipe provenance before spending credits  
Start from latest main after PR 4. Read AGENTS.md.  
One recipe-provenance policy PR. Create branch, implement, test, commit, push, open PR. No deployment.  
## Problem  
Accept All currently freezes outlines.source_recipe_hash.  
If a user later edits the recipe and runs Suggest Sections again against the same Outline, planning can spend credits successfully and only later fail during acceptance because the Outline has immutable provenance for another recipe hash.  
That is an incoherent user workflow.  
## Required policy  
Keep recipe provenance immutable once an Outline contains persisted sections.  
Before any billable outline planning call:  
1. calculate the canonical current recipe hash;  
2. load the validated outline_id;  
3. inspect its frozen recipe hash and current section count.  
Rules:  
* no frozen hash yet → planning allowed;  
* same hash → planning allowed;  
* different hash + outline has persisted sections → return a specific recipe_provenance_conflict before billing;  
* different hash + outline has zero sections → allow a clean re-plan/reset path and ensure stale enrichment provenance is not reused.  
The iOS service must map the specific conflict to a clear user-facing message rather than generic “server error.”  
Do not implement multi-recipe version history in this PR. Do not mutate existing sections to a new recipe. Do not change generation prompts.  
Add tests showing no billable call occurs on a conflicting non-empty Outline.  
PR title:  
```
fix(outline): reject recipe drift before paid planning

```
## PR 10 — Prevent stale project uploads from erasing snapshot sections  
Start from latest main. Read AGENTS.md.  
This is one persistence PR. Create branch, implement, run Swift + SQL/database regression tests, commit, push, open PR. No deployment.  
## Problem  
The recent relational durability migration correctly means snapshot omission no longer deletes an accepted outline_sections row.  
However ProjectCloudSyncService.syncSnapshots() still performs a full PostgREST upsert of project_snapshots.snapshot_json.  
Therefore:  
* relational accepted sections can survive,  
* while the actual snapshot restored by iOS can still be replaced by a stale client payload that omits those sections.  
Protecting only the relational mirror is insufficient.  
## Required invariant  
A stale client snapshot must never remove or downgrade server-authoritative Outline sections merely by omission.  
Explicit section deletion intent must still remove the section.  
Implement this at the server snapshot-write boundary, not with UI timing.  
Prefer a server RPC/transactional snapshot-write path that:  
1. accepts the incoming project snapshot;  
2. resolves canonical project lineage;  
3. reconciles the incoming Outline representation with current relational outline_sections;  
4. retains server sections absent from the client unless explicit delete intent exists;  
5. stores the resulting canonical snapshot_json;  
6. returns the stored row.  
Replace the direct blind snapshot POST in ProjectCloudSyncService with this canonical write path.  
Do not change Accept All worker behavior in this PR.  
## Required regression  
Starting state:  
* relational Outline contains sections A/B;  
* snapshot contains A/B;  
* stale client payload contains no sections.  
After stale upload:  
* relational contains A/B;  
* stored snapshot_json contains A/B.  
Then record explicit deletion of B and upload:  
* relational contains A only;  
* snapshot contains A only.  
Also cover partial older Section Contracts so richer server fields are not nulled by omission.  
PR title:  
```
fix(sync): canonicalize project snapshot writes

```
## PR 11 — Make Accept All client requests deterministic  
Start from latest main. Read AGENTS.md.  
One iOS Accept All request-construction PR. No server semantic changes in this PR.  
Create branch, implement, test, commit, push, open PR. No deployment.  
## Problem  
OutlineSuggestionsReviewView.acceptanceIdempotencyKey currently hashes only:  
* title  
* summary  
* container  
* POV  
* terminal beat  
* Story Arc beat ID  
It omits important Section Contract fields and source recipe identity.  
Separately, SectionEmbedService.startAcceptAll() creates a new random UUID for every section every time the request is constructed.  
Thus the same logical Accept All action is not guaranteed to produce the same request body.  
## Required change  
Create one canonical Accept All request builder.  
First derive a logical batch fingerprint from:  
* project ID  
* Outline ID  
* ordered complete suggestion contracts:    
    * title  
    * summary  
    * container  
    * POV  
    * terminalBeat  
    * entryState  
    * dramaticEvent  
    * resultingChange  
    * terminalState  
    * storyArcBeatID  
    * recipeRequirementIDs  
* complete canonical sourceRecipe  
Do not include the idempotency key in its own fingerprint.  
Generate:  
* the idempotency key from that canonical logical batch;  
* each section UUID deterministically from batch identity + section ordinal.  
Repeated construction from identical inputs must produce byte-equivalent request JSON.  
Do not use random UUIDs for this path.  
Do not change server idempotency behavior yet.  
## Tests  
Prove:  
* same logical batch → same key and section IDs;  
* changing any Section Contract field → different key;  
* changing recipe → different key;  
* changing order → different key;  
* request recreation after view destruction is identical.  
PR title:  
```
fix(accept-all): make client request identity deterministic

```
## PR 12 — Bind Accept All idempotency keys to exact server requests  
Start from latest main after PR 11. Read AGENTS.md.  
One server idempotency PR. Create branch, implement, forward migration, Deno/database tests, commit, push, open PR. No deployment.  
## Problem  
outline_accept_runs is unique only on (user_id, idempotency_key).  
It stores request_json but no request fingerprint.  
On an insert conflict, the server resolves the old run solely from the key. A failed run can then be reset to pending without proving the newly submitted body equals the stored body.  
## Required change  
Add a forward migration:  
```
outline_accept_runs.request_fingerprint text

```
Create a canonical server-side request fingerprint:  
* stable JSON serialization;  
* include the entire immutable request body;  
* exclude only idempotency_key.  
For a new run:  
* store the fingerprint with request_json.  
For duplicate POST:  
* same user + same key + same fingerprint → resolve existing run;  
* same user + same key + different fingerprint → HTTP 409 idempotency_conflict;  
* never replace/rebind the old request_json.  
For legacy rows with null fingerprint:  
* hash stored request_json;  
* if it equals the incoming fingerprint, bind/store the fingerprint and proceed;  
* otherwise conflict.  
Failed-run retry is permitted only for the exact same fingerprint.  
Do not make Accept All transactional in this PR. Do not change section positioning.  
## Tests  
Cover new, duplicate, conflicting and failed-retry cases.  
PR title:  
```
fix(accept-all): bind idempotency to request fingerprint

```
## PR 13 — Validate Accept All canonical ownership and lineage  
Start from latest main after PRs 3 and 12. Read AGENTS.md.  
One backend identity/ownership PR. Create branch, implement, test, commit, push, open PR. No deployment.  
## Problem  
The Accept All server currently proves only that outline_id belongs to the authenticated user.  
Story Arc beat normalization checks beat UUID existence but does not prove the beats belong to the same user/project/StoryArc.  
The request also does not give the backend the canonical project lineage used elsewhere by the app.  
## Required change  
Add project_lineage_id to the Accept All request. iOS sends project.stableLineageID.  
Before creating/starting a run validate the complete graph:  
Authenticated user → requested project/local identity + canonical lineage → Outline → Outline’s StoryArc → every submitted Story Arc beat.  
Also validate:  
* source_recipe_json.project.id == request.project_id;  
* request lineage matches the Outline lineage;  
* each beat belongs to the Outline’s linked StoryArc;  
* any pre-existing submitted section UUID may only already belong to this same Outline/user;  
* snapshot resolution is by canonical lineage, not just local_project_id;  
* multiple snapshots claiming the same canonical identity fail closed rather than choosing arbitrarily.  
Manual/free-form section semantics outside Suggest/Accept All should remain untouched.  
Do not add transactionality here. Do not change planning prompts.  
## Tests  
Attempt and reject:  
* another user’s Outline;  
* another project’s Outline;  
* recipe project mismatch;  
* lineage mismatch;  
* beat from another project;  
* beat from another StoryArc;  
* section UUID collision with another Outline.  
Prove a valid graph succeeds.  
PR title:  
```
fix(accept-all): enforce canonical project ownership

```
## PR 14 — Recompute length contract from the whole Outline  
Start from latest main. Read AGENTS.md.  
One Accept All accounting PR. Create branch, implement, Deno/database test, commit, push, open PR. No deployment.  
## Problem  
runJob() currently calls:  
```
buildLengthContract(normalizedSections)

```
where normalizedSections is only the newly accepted batch.  
It then writes that result onto the entire outlines row.  
Adding sections to an existing Outline therefore replaces projected_word_count with the projection for only the latest batch.  
## Required change  
After the incoming section rows have been materialized, derive the Outline-level length contract from the resulting complete generation-bearing Outline.  
The total must include:  
* pre-existing generation sections;  
* newly accepted sections;  
exactly once.  
If grouping/parent rows can exist, do not double-count a non-generation grouping row and its generation-bearing children.  
Per-section target/min/max derivation for newly inserted sections can remain container-derived.  
Then update:  
* planning_format  
* target_word_count  
* target_word_count_min  
* target_word_count_max  
* projected_word_count  
from the resulting full Outline contract.  
Do not introduce transaction restructuring yet.  
## Regression  
Existing Outline projects to 25,000 words. New accepted batch projects to 35,000 words.  
Final Outline projection must be 60,000, not 35,000.  
Also verify retrying the same section IDs does not inflate the total.  
PR title:  
```
fix(accept-all): compute length from complete outline

```
## PR 15 — Make Accept All authoritative writes atomic  
Start from latest main after PRs 10–14. Read AGENTS.md.  
This PR is exclusively about atomic commit semantics. Do not fold unrelated cleanup into it.  
Create branch, implement with a forward migration, run Deno + database regressions, commit, push, and open a PR. Do not deploy.  
## Problem  
Current accept-outline-sections.runJob() independently performs:  
* recipe provenance freeze;  
* run metadata update;  
* position lookup;  
* section upsert;  
* Outline length update;  
* section acceptance update;  
* progress update;  
* project snapshot merge;  
* final run status.  
If the snapshot step fails, earlier authoritative writes remain committed while the run becomes failed.  
Retry then recomputes basePosition from rows created by the failed attempt and can move the same section IDs farther down the Outline.  
Recipe provenance can also be frozen despite overall failure.  
## Required architecture  
Move the authoritative Accept All commit into one PostgreSQL transaction/RPC, e.g. a narrowly scoped commit_outline_accept_run.  
The transaction must:  
1. lock/validate the Accept run and target Outline;  
2. recheck the already-established request fingerprint/ownership invariants;  
3. enforce recipe provenance under row lock;  
4. assign final section positions deterministically exactly once;  
5. upsert the submitted sections;  
6. mark them accepted;  
7. recompute the complete Outline length contract;  
8. merge those canonical sections into the project snapshot;  
9. mark the run completed with final counters.  
If any authoritative operation fails:  
* the transaction rolls back all of the above;  
* the edge worker may mark the run failed outside the failed transaction;  
* no sections, changed positions, Outline contract, provenance, or partial snapshot from that attempt remain committed.  
Retries of the exact same run/request must be idempotent and must not position-drift.  
Keep the Edge Function responsible for authentication/job orchestration; keep the atomic data mutation in Postgres.  
Do not rewrite project sync, suggestion generation, billing, or UI in this PR.  
## Required database regressions  
Prove:  
**Success**  
* N submitted sections commit;  
* final positions are correct;  
* Outline contract is correct;  
* snapshot contains same sections;  
* run completes N/N.  
**Forced snapshot failure**  
* no submitted sections remain;  
* prior sections are unchanged;  
* Outline provenance is unchanged;  
* Outline length fields are unchanged;  
* snapshot is unchanged;  
* run can subsequently be marked failed.  
**Retry**  
* remove failure condition;  
* retry exact request;  
* succeeds once;  
* same section IDs;  
* same intended positions;  
* no duplicates;  
* no positional drift.  
**Concurrency**  
Two workers cannot commit the same run simultaneously.  
PR title:  
```
fix(accept-all): commit acceptance atomically

```
