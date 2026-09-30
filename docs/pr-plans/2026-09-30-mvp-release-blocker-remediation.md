## StoryDonkey / CathedralOS — MVP Release Blocker Remediation  
## Objective  
Bring the current main branch of kje7713-dev/CathedralOS to a defensible **paid MVP / App Store release candidate**.  
This is **not** a feature-building initiative and **not** a general refactor.  
The core StoryDonkey product is considered substantially complete. The work in this task is to close the remaining release blockers around:  
1. StoreKit purchase correctness  
2. Backend entitlement/credit synchronization  
3. Account deletion  
4. Apple privacy manifest requirements  
5. Subscription legal/compliance surfaces  
6. Public user-generated-content compliance  
7. iOS test-suite correctness and CI enforcement  
8. Production/TestFlight release verification  
Do not redesign unrelated UI, change the writing pipeline, alter generation quality, refactor major architecture, or add unrelated features.  
   
⸻  
   
## Current Repository  
Repository:  
```
kje7713-dev/CathedralOS

```
Work from the latest main.  
At the time of this audit, current main included approximately through:  
```
ec6816b86027c8d81212c61ec3ad498c06331400
refactor(ui): simplify project writing screen (#648)

```
Before making changes:  
```
git checkout main
git pull --ff-only
git status
git log -5 --oneline

```
Record the actual starting SHA in the final report.  
   
⸻  
   
## Product State  
Do **not** treat this as an unfinished prototype.  
The following major MVP functionality already exists and should be preserved:  
* Story/project creation  
* Structured project material  
* Characters  
* Settings/world material  
* Themes/motifs/etc.  
* Recipes / Prompt Packs  
* Commercial story arcs  
* Outline generation  
* Section suggestion  
* Run All / multi-section generation  
* Scene-memory / continuation infrastructure  
* Generated outputs  
* Quick Story / standalone generation  
* Supabase authentication  
* Sign in with Apple  
* Cloud project/output durability  
* Cloud restoration  
* Backend generation  
* Backend credit enforcement  
* OpenAI/provider error handling  
* Provider billing-unavailable handling  
* StoreKit product infrastructure  
* Subscription infrastructure  
* Credit-pack infrastructure  
* EPUB creation  
* EPUB validation  
* EPUB history  
* EPUB deletion  
* EPUB download  
* Standalone-output EPUB generation  
* EPUB sharing  
* Shared Outputs  
* Report Content flow  
* Local hide flow  
* Current StoryDonkey branding  
* Current simplified writing UI  
Do not reopen completed product work unless required to fix one of the release blockers below.  
   
⸻  
   
## Release Position  
The app is close to MVP.  
There is **not** another large product phase required.  
The remaining work is primarily:  
```
commercial correctness
+ App Store compliance
+ release integrity

```
The following issues were found during a current-main repository audit.  
   
⸻  
   
## BLOCKER 1 — StoreKit Backend Validation Is Not Wired Into Production  
## Severity  
```
P0 — Paid launch blocker

```
## Problem  
The app has a production backend validation implementation:  
```
CathedralOSApp/Services/StoreKitValidationService.swift
BackendStoreKitValidationService

```
and the backend has:  
```
supabase/functions/sync-storekit-entitlement

```
However:  
```
StoreKitEntitlementService.shared

```
is initialized with:  
```
init(validationService: StoreKitValidationServiceProtocol? = nil)

```
and repository-wide inspection did not find production code assigning:  
```
StoreKitEntitlementService.shared.validationService = ...

```
or otherwise constructing the shared service with:  
```
BackendStoreKitValidationService(...)

```
The app currently starts the listener roughly as:  
```
StoreKitEntitlementService.shared.startTransactionListener()

```
from:  
```
CathedralOSApp/App/CathedralOSApp.swift

```
without first wiring the backend validator.  
**Consequence**  
A real StoreKit purchase can:  
1. complete successfully with Apple;  
2. update local StoreKit state;  
3. attempt validateWithBackend;  
4. encounter validationService == nil;  
5. throw StoreKitValidationError.notConfigured;  
6. still finish the transaction;  
7. still permit PaywallView to show:  
```
Purchase complete. Credits updated.

```
Meanwhile the server-side credit state may remain unchanged.  
Because generation credits are backend-authoritative, this can create:  
```
user pays
→ UI says purchase succeeded
→ backend does not receive/grant credits
→ subsequent generation says insufficient credits

```
That is unacceptable for a paid release.  
   
⸻  
   
## Required Fix  
Wire production StoreKit validation before any purchase, restore, or transaction-update path can occur.  
The exact architecture is up to you, but the production flow must be equivalent to:  
```
let validator = BackendStoreKitValidationService(
    authService: BackendAuthService.shared
)

StoreKitEntitlementService.shared.validationService = validator
StoreKitEntitlementService.shared.startTransactionListener()

```
or a cleaner dependency-injected equivalent.  
Do not use a test stub in production.  
Do not make the backend validator optional for signed-in production purchases.  
   
⸻  
   
## Required Purchase Semantics  
For a signed-in production user:  
```
Apple verified transaction
        ↓
server validation
        ↓
backend StoreKit transaction recorded idempotently
        ↓
backend entitlement / purchased credit balance updated
        ↓
get-credit-state returns new authoritative balance
        ↓
local UsageLimitService updated from backend result
        ↓
UI says success

```
A local StoreKit entitlement by itself must **not** be treated as final proof of usable credits.  
   
⸻  
   
## Paywall Error Handling  
Current PaywallView calls:  
```
try await entitlementService.purchase(product)

```
then immediately does:  
```
usageLimitService.applyEntitlement(entitlementState)
successMessage = "Purchase complete. Credits updated."

```
Review this carefully.  
The UI must not claim backend credits were updated when backend validation failed.  
For example:  
**Successful Apple + backend transaction**  
```
Purchase complete. Credits updated.

```
**Apple transaction verified but server sync temporarily failed**  
Use a truthful recoverable state such as:  
```
Your purchase was completed, but StoryDonkey couldn't update your credits yet.
Use Restore Purchases to retry.

```
Do **not** tell the user they need to buy again.  
Do **not** lose the verified Apple transaction.  
Do **not** duplicate-credit on retry.  
   
⸻  
   
## BLOCKER 1B — Consumable Credit Pack Restoration / Accounting  
## Severity  
```
P0 if credit packs are offered at launch

```
Review:  
```
CathedralOSApp/Services/StoreKitEntitlementService.swift

```
Current local refresh code appears to calculate:  
```
purchasedCreditBalance

```
by iterating:  
```
Transaction.currentEntitlements

```
and looking for:  
```
StoreKitProductIDs.creditPackIDs

```
This must be validated against StoreKit behavior.  
Credit packs are consumables.  
Do **not** assume consumable purchases are reconstructable as persistent current entitlements.  
The backend ledger should be authoritative for purchased-credit balances.  
   
⸻  
   
## Required Credit-Pack Authority  
The preferred model is:  
```
verified consumable transaction
    ↓
backend transaction ID idempotency
    ↓
backend credit ledger grant
    ↓
backend tracks unused purchased balance
    ↓
get-credit-state is source of truth

```
The iOS app should not attempt to reconstruct lifetime consumable purchases from local StoreKit entitlement state.  
   
⸻  
   
## Required Tests  
Add/repair tests covering at minimum:  
**Purchase**  
* backend validator exists in production wiring;  
* successful purchase calls server validation;  
* server validation result updates displayed/usable backend balance;  
* validation failure does not falsely display “Credits updated”;  
* retry does not duplicate a credit grant.  
**Restore**  
* subscription restore succeeds;  
* backend validation is called;  
* credit state refreshes after restore;  
* repeated restore is idempotent.  
**Credit pack**  
* verified credit pack produces one backend credit grant;  
* replay of same transaction does not double-credit;  
* backend balance is authoritative;  
* local state cannot create paid credits without backend confirmation.  
   
⸻  
   
## BLOCKER 2 — In-App Account Deletion Is Missing  
## Severity  
```
P0 — App Store blocker

```
## Existing Behavior  
The app supports account creation/authentication via:  
```
Sign in with Apple
Supabase Auth

```
The Account screen includes:  
```
Sign Out

```
but repository-wide inspection did not locate:  
```
Delete Account
deleteAccount()
delete user
account-deletion Edge Function
Apple credential revocation

```
Sign-out is not account deletion.  
   
⸻  
   
## Required User Experience  
Add an account-deletion control to:  
```
AccountView

```
Only show it to signed-in users.  
Use a destructive flow with explicit confirmation.  
Example structure:  
```
Delete Account

```
Confirmation should clearly say that deletion removes their StoryDonkey account and associated cloud data.  
Avoid unnecessarily scary language, but make the consequence clear.  
Suggested confirmation:  
```
Delete your StoryDonkey account?

This permanently removes your account and cloud data. This cannot be undone.

```
Require a second destructive confirmation action.  
   
⸻  
   
## Required Backend Behavior  
Create a server-authoritative deletion endpoint.  
Do **not** allow the client anon key to directly delete arbitrary auth users.  
A valid deletion request must:  
1. authenticate the caller;  
2. derive user ID from the verified JWT;  
3. delete or anonymize user-owned cloud data according to schema requirements;  
4. remove public/shared material belonging to that user as appropriate;  
5. handle dependent rows safely;  
6. delete the Supabase Auth user through a privileged backend context;  
7. revoke Sign in with Apple authorization/token where required by the existing authentication architecture;  
8. return explicit success/failure.  
   
⸻  
   
## Data To Audit  
Do not guess table names.  
Inspect current schema/migrations and enumerate all user-owned entities.  
At minimum investigate:  
```
projects
generation outputs
generation usage
credit ledger
entitlements
StoreKit transaction records
shared outputs
shared EPUBs
reports
remix events
story arcs
outline/run state
section memories
embeddings
export history
tombstones
profiles

```
Determine which data must:  
```
DELETE
ANONYMIZE
or RETAIN

```
and why.  
The account-deletion operation must not leave personally attributable public content behind unless intentional and disclosed.  
   
⸻  
   
## Local Data Behavior  
Decide explicitly what happens to device-local drafts after account deletion.  
Recommended MVP behavior:  
```
cloud account/data deleted
local data remains only if technically independent and clearly communicated

```
OR:  
```
delete local + cloud data together

```
Whichever approach is chosen, make it deterministic and test it.  
Do not silently restore deleted cloud data back into a newly created account because of local sync state.  
   
⸻  
   
## Required Tests  
Include:  
* unauthenticated deletion rejected;  
* user can delete only themselves;  
* target user’s cloud rows removed/anonymized correctly;  
* other users’ data unaffected;  
* shared/public artifacts handled correctly;  
* repeated deletion call fails safely/idempotently;  
* client signs out after successful deletion;  
* deleted account cannot immediately rehydrate deleted cloud state from sync;  
* Sign in with Apple cleanup path handled.  
   
⸻  
   
## BLOCKER 3 — Privacy Manifest Missing  
## Severity  
```
P0 — App Store submission blocker/risk

```
The app uses:  
```
UserDefaults

```
in many production files, including but not limited to:  
```
UsageLimitService.swift
GenerationUsageTracker.swift
RecipeSelectionService.swift
DataDurabilityCoordinator.swift
SyncTombstoneService.swift
GenerationOutputSyncService.swift
KindleExportView.swift
ProjectDetailView.swift
CathedralOSApp.swift
HiddenSharedOutputsService.swift

```
Repository inspection found no:  
```
PrivacyInfo.xcprivacy

```
   
⸻  
   
## Required Fix  
Add:  
```
PrivacyInfo.xcprivacy

```
to the correct app target.  
Audit all Apple required-reason APIs used by the app, not only UserDefaults.  
Do not blindly add declarations copied from the internet.  
For every API category:  
1. identify actual usage;  
2. choose an Apple-approved reason that actually matches that usage;  
3. include it in the privacy manifest;  
4. ensure the manifest is packaged in the final IPA.  
At minimum investigate UserDefaults.  
   
⸻  
   
## Required Build Verification  
After building the release IPA:  
```
Payload/CathedralOSApp.app/PrivacyInfo.xcprivacy

```
must exist if appropriate for the current build layout.  
Add a CI or Fastlane verification if practical.  
The release report must state:  
```
privacy manifest packaged: PASS/FAIL

```
   
⸻  
   
## BLOCKER 4 — Subscription Legal / Paywall Requirements  
## Severity  
```
P0 for subscription launch

```
Current:  
```
CathedralOSApp/Features/Account/PaywallView.swift

```
contains subscription and purchase controls but no obvious:  
```
Privacy Policy
Terms of Use

```
links.  
   
⸻  
   
## Required Paywall Additions  
Add accessible links for:  
```
Privacy Policy
Terms of Use

```
to the purchase/paywall experience.  
Use actual production URLs.  
Do not invent URLs.  
If the repository does not contain production URLs, surface this as an explicit operator requirement rather than hardcoding fake links.  
   
⸻  
   
## Subscription Information  
Ensure the subscription UI clearly displays:  
* subscription name;  
* price;  
* billing period;  
* whether it auto-renews;  
* what Pro includes;  
* restore purchases;  
* Privacy Policy;  
* Terms of Use.  
StoreKit’s localized price should remain authoritative.  
Do not hardcode a price where StoreKit can provide it.  
   
⸻  
   
## App Store Metadata Dependency  
Also identify that App Store Connect requires matching:  
```
Privacy Policy URL
Terms/EULA configuration as applicable
subscription metadata
support URL

```
If these cannot be validated from the repository, list them as **external release checklist items**, not code defects.  
   
⸻  
   
## BLOCKER 5 — Public Shared Outputs / UGC Compliance  
## Severity  
```
P0 if public Shared Outputs remain enabled for App Store MVP
P1/Deferred if public discovery is disabled for 1.0

```
The app includes public/user-generated content functionality.  
Current functionality includes at least:  
```
Shared Outputs
Report Content
local hiding of shared outputs
public-sharing backend
remix functionality
shared EPUB publication

```
The current audit found reporting/hiding functionality, but did not identify complete support for:  
```
publication filtering / moderation
blocking abusive users
published support/contact path

```
   
⸻  
   
## MVP Decision Required  
Choose one of these strategies.  
## Option A — Finish UGC compliance for MVP  
Implement a defensible baseline for public Shared Outputs.  
Required components:  
**1. Report content**  
Existing functionality should be verified end-to-end.  
Report must reach backend and persist enough information for operator review without unnecessarily copying private story material.  
**2. Block abusive users**  
Users must be able to block another publisher/user.  
Blocking should prevent that user’s public material from appearing to the blocking user.  
Implement server-side or durable account-scoped block state rather than only a temporary view filter.  
**3. Objectionable-content filtering/moderation**  
Create an actual publication gate.  
Do not rely only on users filing reports after publication.  
For MVP this may be:  
```
automated moderation check before public publication

```
with clear failure behavior.  
Do not block private generation because public publication moderation fails.  
The boundary should be:  
```
private creation allowed
public publishing subject to moderation

```
**4. Contact information**  
Expose a real support/contact path users can reach for abuse or content problems.  
Do not invent an address.  
Use production contact information supplied/configured by the operator.  
   
⸻  
   
## Option B — Disable public discovery for MVP  
This is acceptable and may be preferable for a fast MVP.  
If chosen:  
* preserve EPUB export;  
* preserve ordinary iOS share-sheet file sharing;  
* private user work remains functional;  
* disable or remove public Shared Outputs discovery/publication surfaces from production;  
* ensure public-sharing routes cannot accidentally expose new user content;  
* leave infrastructure intact where safe for a later version.  
Do not delete large amounts of working code unnecessarily.  
Prefer a clean feature gate.  
   
⸻  
   
## Recommended MVP Direction  
Unless public sharing is strategically required for launch:  
```
Feature-gate public Shared Outputs for 1.0.

```
It substantially reduces App Review and moderation risk without harming the central StoryDonkey proposition:  
```
create → structure → generate → revise → compile → export

```
Public social/community behavior can return after launch.  
   
⸻  
   
## BLOCKER 6 — XCTest Suite Is Not Currently A Valid Release Gate  
## Severity  
```
P1 technically, but must be fixed before release candidate

```
Current iOS CI:  
```
.github/workflows/ios.yml

```
runs approximately:  
```
xcodebuild build

```
It does **not** run the XCTest suite.  
Therefore:  
```
CI green != tests green

```
   
⸻  
   
## Known Current Test-Target Defect  
Inspect:  
```
CathedralOSAppTests/RecipeReferenceReconcilerTests.swift

```
The audited version appears to be missing a closing:  
```
}

```
for:  
```
final class RecipeReferenceReconcilerTests: XCTestCase

```
before:  
```
// MARK: - Test helpers
private func makeInMemoryContext() ...

```
Confirm against latest main.  
Do not blindly patch if it has already changed.  
   
⸻  
   
## Test-Gate Requirements  
First make the complete test target compile.  
Then run the full suite.  
Do not limit validation to one previously broken file.  
Use something equivalent to:  
```
xcodebuild test \
  -project CathedralOSApp.xcodeproj \
  -scheme CathedralOSApp \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,OS=latest,name=<available iPhone>" \
  CODE_SIGNING_ALLOWED=NO

```
Resolve all **actual** compile/test failures caused by current main.  
Do not rewrite unrelated functionality just to make weak tests pass.  
If a test is stale or invalid because the production contract deliberately changed, document why before updating the test.  
   
⸻  
   
## CI Requirement  
Update:  
```
.github/workflows/ios.yml

```
so normal PR validation includes both:  
```
build
tests

```
Either:  
```
xcodebuild test

```
which builds before testing,  
or separate jobs.  
The important requirement is:  
```
a PR must not be green when the XCTest target does not compile.

```
   
⸻  
   
## Existing Backend Tests  
Preserve the existing Deno/pgTAP/EPUB validation infrastructure.  
Current repo contains specialized workflows including approximately:  
```
pr-521-ci.yml
pr-4100-a-ci.yml
ios.yml

```
Do not collapse or delete working backend regression coverage as part of this task.  
   
⸻  
   
## BLOCKER 7 — Production Deployment / Source-of-Truth Verification  
## Severity  
```
Release gate

```
Current workflows include:  
```
.github/workflows/testflight.yml
.github/workflows/supabase-deploy.yml

```
Both are manually triggered.  
The deploy workflow itself contains historical comments showing there have been cases where code was merged but an Edge Function had not been included in production deployment.  
Examples included EPUB endpoints and coherence-check deployment.  
Therefore:  
```
merged to main != deployed backend

```
   
⸻  
   
## Required Deployment Audit  
Enumerate every production Edge Function in:  
```
supabase/functions/

```
and compare it with:  
```
.github/workflows/supabase-deploy.yml

```
Produce a table:  

| Edge Function | Exists | Deployed by workflow | JWT mode | Used by iOS | Status |
| ------------- | ------ | -------------------- | -------- | ----------- | ------ |
  
Identify omissions.  
Do not change JWT verification mode casually.  
Particularly scrutinize any endpoint using:  
```
--no-verify-jwt

```
and prove it implements its own correct authentication/authorization where required.  
   
⸻  
   
## Migration Audit  
Inspect the full migration chain.  
There are known historical issues where disposable Supabase reset required special handling for older migrations.  
Current CI includes workarounds around historical migration ordering/repair.  
Do not rewrite old applied production migrations just to make local reset aesthetically clean.  
Instead answer:  
1. Can production migrate forward from its actual current state?  
2. Can a fresh disposable DB be constructed honestly enough for regression testing?  
3. Are current migrations after the known historical defect deterministic?  
4. Are any test-only SQL files incorrectly sitting in supabase/migrations and at risk of production execution?  
Pay particular attention to files named like:  
```
test_accept_all_snapshot_trigger.sql
test_outline_section_snapshot_durability.sql
test_section_memory_lineage.sql

```
If they are truly tests and not migrations, determine whether they belong elsewhere.  
Do not relocate them without understanding how current production/deploy tooling treats them.  
   
⸻  
   
## RELEASE CANDIDATE SMOKE TEST  
After all blockers are fixed, produce one TestFlight release candidate from the exact tested commit.  
Run the following end-to-end flow using a clean user/account where practical.  
   
⸻  
   
## Authentication  
```
PASS Sign in with Apple
PASS session persists after relaunch
PASS sign out
PASS sign back in

```
   
⸻  
   
## Account  
```
PASS backend credit state loads
PASS correct user identity
PASS account deletion UI visible when signed in
PASS destructive confirmation works

```
Actual account deletion may use a disposable test account.  
   
⸻  
   
## Project Creation  
```
PASS create project
PASS add/edit core story material
PASS create/select recipe
PASS save
PASS close app
PASS reopen project
PASS material still present

```
   
⸻  
   
## Story Arc / Outline  
```
PASS select commercial story arc
PASS generate/suggest outline
PASS accept sections
PASS no material silently disappears
PASS section IDs remain stable

```
   
⸻  
   
## Run All  
Use a meaningful multi-section project.  
Verify:  
```
PASS run starts
PASS progress advances
PASS generated section outputs persist
PASS memory pipeline completes
PASS app resumes correctly after background/relaunch
PASS final outputs associate with sections
PASS no empty Generated Output state after successful run

```
   
⸻  
   
## Quick Story  
```
PASS create standalone story
PASS generate
PASS output persists
PASS title/output correct
PASS reopen output

```
   
⸻  
   
## Credits  
**Free-user behavior**  
```
PASS backend credit balance displayed
PASS generation deducts expected amount
PASS failed generation is not charged
PASS insufficient credit fails before/provider call where appropriate
PASS server remains final authority

```
**Purchase**  
In StoreKit sandbox/TestFlight:  
```
PASS product loads
PASS purchase succeeds
PASS backend receives validated transaction
PASS backend ledger changes once
PASS get-credit-state reflects new balance
PASS UI refreshes to backend balance
PASS user can immediately spend purchased credits

```
**Replay**  
```
PASS retry/restore does not double grant

```
**Restore**  
```
PASS restore works
PASS subscription restored where applicable
PASS backend sync performed
PASS credit state refresh performed

```
   
⸻  
   
## Provider Failure  
Verify current provider-billing behavior remains intact:  
```
PASS provider billing exhaustion produces friendly user message
PASS no user credits charged
PASS no infinite retry loop
PASS operator alert emitted through expected path

```
Do not regress the recent provider-billing work.  
   
⸻  
   
## EPUB  
Test both:  
```
project/novel EPUB
standalone story EPUB

```
Verify:  
```
PASS export succeeds
PASS EPUBCheck path passes
PASS previous exports list
PASS download works
PASS delete works
PASS history persists correctly
PASS acknowledgements metadata correct
PASS commercial story-arc part naming correct

```
   
⸻  
   
## Reinstall / Recovery  
For a signed-in disposable user:  
```
create project
generate content
sync
delete app
reinstall TestFlight build
sign back in
restore/sync

```
Verify:  
```
PASS project recovered
PASS outline recovered
PASS outputs recovered
PASS outputs attached to correct sections
PASS no deleted/tombstoned project resurrection

```
   
⸻  
   
## App Store Release Checklist  
Code changes alone are not enough.  
Produce a final section listing external operator actions still required in App Store Connect.  
Audit at minimum:  
```
App name
StoryDonkey branding
bundle identifier
version/build number
app icon
screenshots
description
keywords
support URL
privacy-policy URL
Terms/EULA
privacy questionnaire
Sign in with Apple capability
StoreKit products
subscription product metadata
subscription review screenshots
subscription availability
banking/tax agreements
age rating
content declarations
review notes
TestFlight build

```
Mark each as:  
```
VERIFIED
NEEDS OPERATOR
NOT APPLICABLE

```
Do not mark an App Store Connect item verified unless there is actual evidence.  
   
⸻  
   
## Documentation Cleanup  
After production correctness is established, update stale docs.  
Current README still describes things such as:  
```
Backend-backed generation
Saved output sync
Public sharing
Pricing / credits

```
as planned/in progress even though much of this functionality now exists.  
Update:  
```
README.md

```
and any directly misleading architecture docs.  
Do not spend substantial time polishing documentation unrelated to release correctness.  
   
⸻  
   
## Old Warning Comments  
Several files still contain warnings equivalent to:  
```
Backend enforcement is required before public monetized release.

```
Some of these comments may now be stale because backend enforcement has been implemented.  
Audit them.  
If the underlying warning is still true, leave/fix the implementation.  
If the implementation is now production-authoritative, update the comment.  
Do not delete warnings just to make the repo look finished.  
   
⸻  
   
## Architecture Rules  
## Backend Authority  
For money/credits:  
```
backend is authoritative

```
The client may cache/display optimistic state, but cannot mint paid value.  
   
⸻  
   
## User Identity  
Never trust:  
```
user_id
email
account ID

```
from arbitrary request bodies for ownership decisions.  
Derive authenticated user identity from the verified session/JWT.  
   
⸻  
   
## StoreKit  
Never grant paid entitlement from unverified transactions.  
Never double-grant a StoreKit transaction.  
Use transaction identifiers/idempotency.  
   
⸻  
   
## Credits  
Failed LLM calls must not consume credits unless an explicitly documented policy says otherwise.  
Current desired behavior remains:  
```
successful billable result → charge
provider failure → no charge
insufficient credits → no provider call / no charge
idempotent retry → no duplicate charge

```
   
⸻  
   
## Data Durability  
Do not solve a release issue by weakening cloud/local reconciliation.  
Preserve:  
```
lineage
tombstones
authoritative project recovery
generation-output reconciliation
section-output identity
scene-memory lifecycle

```
   
⸻  
   
## Migrations  
Do not edit old production migrations casually.  
Prefer forward correction migrations.  
   
⸻  
   
## Security  
Never put:  
```
OpenAI API key
Supabase service-role key
Apple private credentials
Resend/API secrets

```
in iOS source or committed repository files.  
   
⸻  
   
## Scope Guardrails  
Do **not**:  
* redesign the Home screen;  
* redesign Project Detail;  
* alter StoryDonkey branding;  
* rebuild Prompt Packs;  
* rewrite the scene-memory system;  
* replace SwiftData;  
* replace Supabase;  
* replace StoreKit;  
* change OpenAI models without necessity;  
* tune story-writing prompts;  
* introduce a new subscription model;  
* change credit pricing;  
* change existing user pricing;  
* rework EPUB styling for aesthetics;  
* add Android;  
* add web;  
* add macOS;  
* build social features beyond what compliance requires;  
* perform speculative architecture cleanup.  
Every code change must connect to a documented release blocker.  
   
⸻  
   
## Suggested PR Sequence  
Do not make one enormous unreviewable PR.  
## PR 1 — StoreKit Production Authority  
Scope:  
```
wire BackendStoreKitValidationService
correct success/failure semantics
backend balance refresh
fix consumable credit handling
tests

```
Acceptance:  
```
sandbox purchase → backend ledger → usable credits

```
   
⸻  
   
## PR 2 — Account Deletion  
Scope:  
```
backend deletion endpoint
auth ownership
cloud-data cleanup
Sign in with Apple cleanup
AccountView deletion UI
tests

```
   
⸻  
   
## PR 3 — App Store Compliance Surface  
Scope:  
```
PrivacyInfo.xcprivacy
privacy-policy link
Terms link
support/contact configuration
subscription disclosure cleanup

```
If URLs are unavailable, implement configuration points and explicitly report operator dependency.  
   
⸻  
   
## PR 4 — Public UGC Decision  
Preferred MVP:  
```
feature-gate public discovery/publishing

```
OR, if specifically required:  
```
moderation
reporting verification
user blocking
support/contact
tests

```
Do not silently decide which strategy to ship. If no existing product decision is encoded, prepare the safer MVP implementation as a bounded feature flag and document it.  
   
⸻  
   
## PR 5 — XCTest / CI Release Gate  
Scope:  
```
repair test-target compilation
run complete XCTest suite
fix legitimate regressions
xcodebuild test in CI

```
   
⸻  
   
## PR 6 — Release/Deployment Hardening  
Scope only if needed:  
```
missing deploy steps
migration safety fixes
release verification
stale README

```
   
⸻  
   
## Proof Required For Every PR  
Each PR description must contain:  
## Summary  
What problem is being fixed.  
## Root Cause  
Specific code/architecture issue.  
## Files Changed  
Exact files.  
## Tests  
Exact commands and results.  
Do not write:  
```
tests passed

```
without command evidence.  
## Risk  
What could regress.  
## Rollback  
How this PR can be safely reverted.  
## Out of Scope  
What was intentionally not changed.  
   
⸻  
   
## Final Release Audit Required  
After all relevant PRs are merged, inspect current main again rather than assuming each PR composed correctly.  
Produce:  
```
# StoryDonkey MVP Final Release Audit

Starting SHA:
Final SHA:

## P0 Blockers
- [x] StoreKit backend authority
- [x] StoreKit consumable credit correctness
- [x] Account deletion
- [x] Privacy manifest
- [x] Subscription legal links
- [x] Public UGC handled/disabled

## Engineering Release Gates
- [x] iOS app builds
- [x] XCTest target compiles
- [x] full XCTest suite passes
- [x] Deno regression suite passes
- [x] pgTAP regression suite passes
- [x] EPUBCheck path passes
- [x] Supabase deploy coverage audited
- [x] current backend deployed
- [x] TestFlight release candidate uploaded

## End-to-End Smoke Test
- [x] auth
- [x] project creation
- [x] outline generation
- [x] Run All
- [x] Quick Story
- [x] generation credits
- [x] StoreKit purchase
- [x] StoreKit restore
- [x] EPUB
- [x] reinstall/cloud restore

## Remaining Non-Blocking Debt

...

## External Operator Actions

...

## Release Recommendation

READY FOR MVP SUBMISSION

or

NOT READY

with exact remaining blockers.

```
Do not mark the app ready because the build compiles.  
“Ready” means the paid customer flow, account lifecycle, App Store requirements, backend deployment, test gates, and recovery path have all been demonstrated.  
   
⸻  
   
## Most Important Immediate Investigation  
Start with **StoreKit**, before touching the other items.  
Specifically answer these questions from current code:  
1. Where is StoreKitEntitlementService.shared.validationService configured in production?  
2. If nowhere, prove the current purchase path can reach notConfigured.  
3. After an Apple purchase succeeds but backend validation fails, what exact message does the user currently see?  
4. Does the StoreKit transaction still get finished?  
5. Can get-credit-state remain unchanged after that transaction?  
6. How are consumable credit packs reconstructed after relaunch?  
7. Is Transaction.currentEntitlements being incorrectly used as the authority for consumable credits?  
8. What is the smallest production-safe fix?  
Do not implement unrelated changes until this path is understood.  
   
⸻  
   
## Definition of Done  
The task is complete when a brand-new customer can realistically do this:  
```
download StoryDonkey
→ Sign in with Apple
→ create a project
→ develop story material
→ build an outline
→ generate a story
→ buy credits / subscribe if needed
→ immediately use what they bought
→ close and reopen the app without losing work
→ export the completed work as EPUB
→ restore their work on reinstall
→ restore legitimate purchases
→ delete their account if they choose

```
and the application has passed its automated test gates and production deployment checks.  
That is the MVP bar.  
Anything beyond that is post-MVP unless it directly prevents the above workflow from being safe, correct, and App Store-compliant.  

---

## Execution Bookmark

Updated 2026-09-30 08:03 EDT.

- **Starting SHA:** `83a9b10d66affba4dc5e794fa268bead1cecf331` (`main`, PR #654 merged and deployed).
- **Plan saved:** this file is the canonical MVP release-blocker remediation plan.
- **Completed before this plan:** StoreKit backend-authority work (#649), XCTest realignment (#650–#652), and AI-cover pricing follow-up (#654).
- **Current plan status:** PR 1 (StoreKit Production Authority) is satisfied by the existing shipped work; this must be re-verified against current `main` before marking the blocker closed.
- **PR 2 status:** implementation committed as `43ab15f` plus bookmark update `44ae274` on `feat/account-deletion`; PR #655 is open for review. No merge, Supabase deployment, or TestFlight deployment performed.
- **PR 2 validation:** Edge Function `deno check` passed; focused Edge Function tests passed 2/2; iOS build not available on this Linux host.
- **PR 3 status:** implementation committed as `60c5bc6` on `feat/app-store-compliance`; PR #656 is open for review. No merge, Supabase deployment, or TestFlight deployment performed.
- **PR 3 scope:** registered `PrivacyInfo.xcprivacy`, added configurable legal-link slots and truthful missing-URL messaging, and documented App Store Connect/archive dependencies.
- **PR 3 validation:** privacy manifest parsed as a plist; `git diff --check` passed; iOS build not available on this Linux host.
- **Next PR:** **PR 4 — Public UGC Decision**.
- **Next action:** leave PRs #655 and #656 open for review and prepare the PR 4 decision/implementation from latest `main` without merging or deploying.

### Bookmark rules

Update this section after each meaningful milestone with the current SHA, PR number, tests, deployment status, and the next unfinished PR. Do not mark a blocker complete without current-main evidence.
