You are working in the current kje7713-dev/CathedralOS repository.  
Implement the **smallest possible set of changes required to provide a credible minimal UGC-compliance implementation for StoryDonkey while preserving every existing feature and flow.**  
This is not a moderation-platform project.  
## Governing implementation rule  
**Preserve the existing architecture and behavior unless a change is strictly necessary for compliance.**  
Specifically:  
* Do not disable any existing feature.  
* Do not remove or restrict EPUB functionality.  
* Do not remove public sharing.  
* Do not remove remixing.  
* Do not change normal generation behavior.  
* Do not change existing cloud-sync behavior.  
* Do not change existing embedding behavior except to attach the minimum additional eligibility check.  
* Do not redesign existing publication flows.  
* Do not introduce an admin application.  
* Do not introduce a generalized moderation system.  
* Do not introduce a moderation queue.  
* Do not introduce user scoring/reputation.  
* Do not add unrelated “best practice” infrastructure.  
Prefer adding a few fields, one small service call, one small block relationship, and small UI additions over creating new subsystems.  
The implementation should be additive and surgical.  
   
⸻  
   
## Required compliance surface  
Implement only the following:  
1. automated public-sharing eligibility check for **sexual content involving minors**;  
2. user-visible eligibility state;  
3. existing report functionality completed where necessary;  
4. minimal creator blocking;  
5. reachable support/contact information;  
6. existing/manual operator ability to unpublish reported public content.  
Nothing broader is requested.  
   
⸻  
   
## 1. Audit current main first  
Before modifying code, inspect the current implementation of:  
* section embeddings;  
* embedding generation lifecycle;  
* section identity/content hashing if already present;  
* public sharing;  
* EPUB publication;  
* remixing;  
* shared outputs;  
* report UI/API;  
* shared_output_reports;  
* account deletion;  
* RLS;  
* existing email alert infrastructure;  
* existing operator/unpublish functionality;  
* support/legal URL configuration.  
Identify the smallest points where the required functionality can attach to existing flows.  
Then implement it.  
Do not stop at a plan.  
   
⸻  
   
## 2. Piggyback the eligibility check on the existing section-embedding lifecycle  
StoryDonkey already processes sections to create/update embeddings.  
Use that lifecycle rather than creating a separate manuscript-moderation pipeline.  
Conceptually:  
section changes → existing embedding processing → existing embedding saved → lightweight moderation eligibility check → eligibility metadata saved  
The moderation call is separate from the embedding API request, but it should run as part of the same existing section-processing lifecycle where practical.  
Do not introduce another background-processing architecture unless the existing architecture makes that unavoidable.  
   
⸻  
   
## 3. The automated check covers ONE thing only  
The automated public-sharing eligibility check is only for:  
**sexual content involving minors**  
Use OpenAI:  
```
omni-moderation-latest

```
and specifically the provider’s:  
```
sexual/minors

```
classification.  
Do not use other moderation categories to prevent publication.  
Do not block public sharing based on:  
* violence;  
* graphic violence;  
* profanity;  
* adult consensual sexual content;  
* drugs;  
* crime;  
* horror;  
* self-harm themes;  
* harassment;  
* hate classifications;  
* political content;  
* offensive ideas;  
* disturbing fiction;  
* general mature themes.  
Do not introduce additional thresholds or custom censorship policy.  
Do not use a generative LLM prompt.  
   
⸻  
   
## 4. Private writing remains fully functional  
A restricted public-sharing status must NOT:  
* prevent generation;  
* prevent editing;  
* prevent saving;  
* prevent cloud sync;  
* prevent embeddings;  
* delete content;  
* alter content;  
* prevent private EPUB creation;  
* prevent private EPUB export;  
* consume credits;  
* affect subscriptions.  
It affects only whether the material can be made public through StoryDonkey.  
   
⸻  
   
## 5. Store the minimum eligibility state  
First inspect whether the existing section/embedding schema already has a suitable metadata field or extensible structure.  
Reuse existing storage if doing so is clean and type-safe.  
Only add new database columns if necessary.  
Avoid creating a separate moderation table unless the existing schema genuinely cannot support the required state.  
The minimum information needed is conceptually:  
* identity/hash of the section content that was reviewed;  
* whether that exact content is eligible for public sharing;  
* time checked.  
Optionally store the model/policy version only if needed to make stale results distinguishable.  
A possible representation is:  
public_sharing_eligible public_sharing_checked_content_hash public_sharing_checked_at  
Because there is currently only one automated restriction reason, avoid creating elaborate category schemas.  
If a reason field is useful for clean UI/domain modeling, the only current value should be:  
```
sexual_content_involving_minors

```
Choose the smallest implementation that fits current schema conventions.  
   
⸻  
   
## 6. Content changes invalidate the prior result  
Eligibility belongs to the exact reviewed section content.  
If the section changes:  
```
current hash != reviewed hash

```
the previous eligibility result is stale.  
When the normal embedding update lifecycle runs for the changed section, run the moderation eligibility check again and save the result corresponding to the new content.  
Reuse an existing section content hash if the project already maintains one.  
Do not add a second hashing implementation unnecessarily.  
   
⸻  
   
## 7. No credits and no billing events  
The OpenAI moderation endpoint is not a StoryDonkey generation operation.  
It must not:  
* debit user credits;  
* reserve credits;  
* consume Pro monthly credits;  
* create billable generation events;  
* affect generation budget calculations.  
Reuse the existing server-side OpenAI credential.  
Never expose it to the iOS application.  
   
⸻  
   
## 8. User disclosure  
Because this eligibility check occurs during ordinary section processing rather than only when Publish is tapped, the user must receive accurate disclosure.  
Add the smallest non-disruptive disclosure consistent with the existing UI.  
Preferred language:  
**Public Sharing Eligibility**  
StoryDonkey checks sections for content that cannot be shared publicly. This does not restrict what you can write, save, edit, or privately export.  
If more detail is appropriate:  
StoryDonkey uses an automated check for sexual content involving minors. Content identified by this check remains fully available privately but cannot be published through StoryDonkey.  
Do not imply that StoryDonkey broadly moderates private writing.  
Do not show a blocking confirmation every time a section embedding is generated.  
Prefer a one-time acknowledgement or appropriately placed persistent explanation using existing settings/onboarding patterns.  
Do not materially disrupt existing writing flows.  
   
⸻  
   
## 9. Expose eligibility to the author  
Expose the state at the section level using the smallest existing UI surface that makes sense.  
Examples:  
```
Public Sharing: Eligible

```
or:  
```
Public Sharing: Restricted

```
For a restricted section, provide concise explanation:  
“This section can’t be shared publicly because the automated safety check identified sexual content involving a minor.”  
Also state:  
“This does not affect private writing or export.”  
Do not expose raw OpenAI scores.  
Do not expose provider JSON.  
Do not use accusatory language.  
If the eligibility check has not yet run or the stored hash is stale, distinguish that from a rejection.  
For example:  
```
Public Sharing: Checking…

```
or:  
```
Public Sharing: Not yet checked

```
depending on current async behavior.  
   
⸻  
   
## 10. Derive project/novel eligibility from its sections  
Do not create a second mutable project-level moderation system unless absolutely necessary.  
Where practical, derive public-sharing eligibility from current section eligibility.  
Conceptually:  
* all current included sections eligible → public sharing allowed;  
* any current included section restricted → public publication prevented;  
* any required current section has stale/missing eligibility → complete its eligibility check before publication.  
When publication is prevented, identify the affected section(s) so the author knows what needs attention.  
Do not scan the full manuscript again if every constituent section’s current content has already been checked.  
   
⸻  
   
## 11. Preserve EPUB publication completely  
Public EPUB publication is required and must remain functional.  
Do not:  
* disable it;  
* hide it;  
* feature-flag it off;  
* replace it;  
* reduce its capabilities.  
Use the section eligibility state already produced during section processing.  
When publishing an EPUB:  
1. determine which current sections comprise the canonical manuscript;  
2. verify those current section contents have current eligibility results;  
3. verify none are restricted;  
4. verify any additional user-controlled public text not represented by those sections if necessary;  
5. proceed through the existing EPUB publication flow unchanged.  
Do not re-moderate a complete novel when the exact constituent section contents have already been checked.  
If a section changed and its eligibility result is stale, check only that changed/current section before publication.  
Private EPUB generation/export is unaffected.  
   
⸻  
   
## 12. Preserve ordinary public-sharing flows  
Apply the same principle to ordinary public output sharing.  
Do not replace the current publication implementation.  
At the last appropriate server-authoritative point before making material public:  
* confirm the relevant current content has a valid eligibility result;  
* reject public publication if sexual/minors restricted;  
* otherwise continue through the existing publication flow.  
Do not move normal sharing logic into a new service merely for moderation.  
   
⸻  
   
## 13. Reporting: reuse what already exists  
StoryDonkey already has shared_output_reports.  
Audit the implementation and retain it.  
Only add missing functionality required to make it actually usable.  
Verify:  
* public content has a Report action;  
* reports persist;  
* reporter identity comes from authentication;  
* reason/details continue to work;  
* users cannot alter other users’ reports;  
* report targets are validated.  
Do not rebuild reporting.  
Do not build a moderation dashboard.  
   
⸻  
   
## 14. Report notification: use the existing alert infrastructure  
Inspect the repository for the existing server-side email/notification mechanism.  
If one already exists, reuse it.  
When a report is successfully stored, send the operator a minimal alert containing:  
* report ID;  
* shared-output ID;  
* report reason;  
* timestamp.  
Do not include unnecessary manuscript/user data.  
If notification fails after the report is stored, preserve the report.  
Do not make a notification-provider failure cause the user’s report submission to disappear.  
   
⸻  
   
## 15. Operator response remains deliberately manual  
Do not build an admin UI.  
Verify/document the existing secure way for the operator to:  
* locate the reported shared output;  
* unpublish it;  
* mark the report appropriately.  
If the existing backend already supports unpublishing, reuse it.  
Only add a small operator-side function if no safe existing method exists.  
No ordinary client may receive service-role/admin privileges.  
   
⸻  
   
## 16. Add the smallest possible creator-blocking implementation  
Apple requires users to be able to block abusive users.  
Implement only that capability.  
Prefer one simple backend relationship equivalent to:  
```
user_blocks

```
with:  
* blocker_user_id;  
* blocked_user_id;  
* created_at.  
Use an existing generic ID column only if repository conventions require it.  
Requirements:  
* authenticated blocker identity must come from JWT;  
* users cannot block themselves;  
* blocker/blocked pair is unique;  
* RLS prevents modifying another user’s block list;  
* account deletion cleans up relationships.  
Do not add:  
* follows;  
* friends;  
* messaging;  
* social graphs;  
* reputation;  
* mutual block semantics;  
* moderation strikes;  
* shadow bans.  
   
⸻  
   
## 17. Block Creator UI  
On another creator’s public content add:  
```
Block Creator

```
Use a simple confirmation:  
“Stories from this creator will no longer appear for you.”  
After blocking, that creator’s content should no longer appear to that authenticated user in the existing public browse/detail/remix surfaces where practical.  
Enforce this server-side rather than relying solely on Swift filtering.  
Provide a minimal Unblock capability in the existing Account/Settings area.  
Do not redesign browsing.  
   
⸻  
   
## 18. Support/contact  
Add only what is required to expose reachable developer contact information.  
Reuse existing release configuration conventions.  
If absent, add configuration equivalent to:  
SUPPORT_EMAIL and/or SUPPORT_URL  
Do not invent production values.  
Expose Contact/Support alongside existing Privacy Policy and Terms surfaces.  
Update release validation only as necessary to prevent shipping with a missing required production contact.  
   
⸻  
   
## 19. Account deletion  
Make only the changes needed for newly introduced block/eligibility data.  
Eligibility metadata attached to sections should naturally follow the lifecycle of the section/embedding.  
user_blocks should delete appropriately when either relevant account is deleted.  
Do not rewrite the existing account-deletion pipeline.  
Add focused regression coverage proving the new relationships do not break it.  
   
⸻  
   
## 20. Testing  
Use the existing test infrastructure.  
Do not create an oversized moderation test suite.  
Add only enough tests to prove the new compliance boundaries.  
## Eligibility  
Prove:  
* embedding/section processing still works normally;  
* moderation eligibility check runs as part of the intended lifecycle;  
* sexual/minors positive result marks the section public-sharing restricted;  
* other moderation categories do not restrict public sharing;  
* moderation consumes zero StoryDonkey credits;  
* editing a section invalidates/replaces the prior eligibility result;  
* generation/edit/save/export remain unaffected.  
## Publication  
Prove:  
* eligible section can still publish through existing flow;  
* restricted section cannot become public;  
* eligible multi-section novel/EPUB can publish;  
* one restricted section prevents public novel/EPUB publication;  
* unchanged already-checked sections are not unnecessarily rechecked;  
* private EPUB export works exactly as before.  
## Reporting  
Prove the existing reporting path still works and any new notification hook does not break report persistence.  
## Blocking  
Prove:  
* create block;  
* self-block fails;  
* duplicate handling is safe;  
* blocked creator disappears for blocker;  
* other users are unaffected;  
* unblock works;  
* RLS protects the relationship.  
## Regression  
Run the existing relevant generation, embeddings, public-sharing, EPUB, cloud sync, and account-deletion tests.  
Existing flows must remain intact.  
   
⸻  
   
## 21. Minimal App Review evidence  
Create/update:  
```
docs/release/ugc-moderation-compliance.md

```
Keep it factual and short.  
Document:  

| Requirement | Implementation |
| ------------------ | -------------------------------------------------------------------------- |
| Pre-post filtering | Section-level sexual/minors eligibility check using omni-moderation-latest |
| Reporting | Existing StoryDonkey report flow |
| Blocking | Minimal Block Creator implementation |
| Response | Operator notification + existing/manual unpublish workflow |
| Contact | StoryDonkey support contact |
  
Also explain:  
* eligibility is calculated during existing section processing;  
* private writing is never disabled or deleted;  
* the restriction affects only public StoryDonkey publication;  
* EPUB publication remains fully supported;  
* public novels reuse current section eligibility rather than rescanning complete books.  
Do not claim broader moderation than exists.  
   
⸻  
   
## 22. Scope discipline  
This requirement is critical.  
If you encounter a problem, first look for the smallest change that works with existing architecture.  
Do not solve problems by:  
* disabling functionality;  
* redesigning workflows;  
* adding generalized infrastructure;  
* adding extra moderation categories;  
* replacing existing services;  
* introducing new abstractions with no immediate requirement.  
Do not implement speculative future moderation functionality.  
The target is not an idealized safety platform.  
The target is a **minimal viable compliance layer attached to StoryDonkey’s existing product**.  
   
⸻  
   
## Success condition  
The implementation is complete when:  
* existing writing/generation/editing/sync/embedding behavior remains intact;  
* existing public sharing remains intact;  
* existing EPUB functionality remains intact;  
* section processing records whether the current section is eligible for public sharing based only on sexual/minors;  
* that status is visible to the author;  
* material restricted for this reason cannot become public;  
* private use/export remains unaffected;  
* existing reporting works;  
* users can block creators;  
* the operator can receive reports and manually unpublish content;  
* support contact is exposed;  
* no moderation credit charge exists;  
* no unnecessary moderation architecture has been introduced.  
   
⸻  
   
## Final report  
When finished provide:  
1. branch and head SHA;  
2. exact files changed;  
3. exact schema changes;  
4. where eligibility state was stored and why that was the smallest option;  
5. where in the existing embedding lifecycle the moderation call was attached;  
6. confirmation that only sexual/minors affects automated eligibility;  
7. exact user-facing eligibility UI;  
8. confirmation all private functionality remains intact;  
9. confirmation public EPUB functionality remains intact;  
10. confirmation normal sharing/remix flows remain intact;  
11. blocking implementation;  
12. reporting/notification implementation;  
13. operator unpublish procedure;  
14. support configuration still required;  
15. tests run and results;  
16. any remaining item required for the minimal compliance implementation.  
If the implementation required a larger architectural modification than anticipated, explicitly explain why the existing architecture could not support the smaller approach before considering that work complete.  
