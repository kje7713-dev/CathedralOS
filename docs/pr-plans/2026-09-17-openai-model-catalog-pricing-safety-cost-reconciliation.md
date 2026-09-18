**CathedralOS OpenAI Model Catalog, Pricing Safety, and Cost Reconciliation PR Bundle**  
  
**Status: implementation plan only**  
**Repository: kje7713-dev/CathedralOS**  
**Verified repository baseline: main at 714767e60e15e8a6a42705a4397de020236777ac (fix(outline): sharpen section quality guidance (#591))**  
**Production Supabase project inspected: vrzlwukuslpnqebaakxy**  
**Plan snapshot date: 2026-09-17**  
  
> **Agent instruction:** Re-check `main` and production schema before beginning. This document records the verified starting point above; do not blindly assume the SHA or schema is unchanged when implementation starts.  
  
  
  
**1. Objective**  
  
**Make CathedralOS model availability and billing safe enough that a newly released OpenAI model can be discovered automatically without ever becoming customer-usable before its pricing is known and validated.**  
  
**The end state must have these properties:**  
  
**	1.	OpenAI is the source for which provider models exist and are available.**  
**	2.	Official OpenAI model/pricing documentation is checked automatically for current provider token rates.**  
**	3.	public.generation_models is the only live runtime source of truth for the provider rates used to calculate Cathedral customer charges.**  
**	4.	A text-generation model with incomplete, null, unverified, or otherwise unusable pricing is not returned by the model picker and cannot be invoked by a stale or malicious client.**  
**	5.	A newly discovered model such as gpt-6-astra may be recorded in the catalog, and its pricing may be discovered automatically, but it remains operator-disabled by default until Cathedral explicitly chooses to offer it.**  
**	6.	Existing customer billing remains actual token usage × the request-time provider rate × the configured Cathedral billing multiplier, subject only to existing intended product-floor behavior. This bundle is not permission to redesign pricing.**  
**	7.	OpenAI organization Costs and Usage API data is recorded on a schedule so Cathedral can compare:**  
**	●	what Cathedral believed provider COGS were,**  
**	●	what Cathedral actually charged the customer,**  
**	●	what OpenAI actually charged the OpenAI project,**  
**	●	and whether provider token counts agree with Cathedral telemetry.**  
**	8.	Legacy public.model_rates is removed as an active pricing authority only after all live consumers have been migrated and proven.**  
**	9.	Historical settled generations are never repriced or retroactively rebilled.**  
**	10.	Failure is safe:**  
**	●	unknown price is never treated as $0,**  
**	●	a parser failure never overwrites a known-good price,**  
**	●	a provider-list failure never marks the entire catalog unavailable,**  
**	●	an admin-cost sync failure never changes customer billing.**  
  
  
  
**2. Verified current state**  
  
**This section is based on the current repository and production Supabase inspection, not on a hypothetical architecture.**  
  
**2.1 Current model catalog path**  
  
**The app’s model picker currently flows through:**  
  
```text  
CathedralOSApp/Services/GenerationModelService.swift  
        |  
        v  
GET generation-models Edge Function  
        |  
        v  
SupabaseGenerationModelStore.listEnabledModels()  
        |  
        v  
public.generation_models  
```  
  
**Relevant current files:**  
  
**	●	CathedralOSApp/Services/GenerationModelService.swift**  
**	●	supabase/functions/generation-models/index.ts**  
**	●	supabase/functions/generate-story/_generation_models.ts**  
  
**GenerationModelService.swift simply fetches the Edge Function result and sorts it. It does not perform a pricing-safety filter.**  
  
**generation-models/index.ts authenticates the caller and then calls listEnabledModels().**  
  
**SupabaseGenerationModelStore.listEnabledModels() currently filters on enabled = true; it does not require complete provider pricing.**  
  
**Therefore, the server is the correct place to enforce customer model eligibility. Do not build a safety rule only in Swift.**  
  
**2.2 Current production generation_models schema**  
  
**Production currently has:**  
  
```text  
id  
provider  
provider_model  
display_name  
description  
input_credit_rate  
output_credit_rate  
minimum_charge_credits  
max_output_tokens  
enabled  
sort_order  
created_at  
updated_at  
provider_input_usd_per_1m  
provider_cached_input_usd_per_1m  
provider_output_usd_per_1m  
billing_multiplier  
pricing_effective_at  
```  
  
**Important verified facts:**  
  
**	●	Provider pricing columns are nullable.**  
**	●	billing_multiplier is non-null and defaults to 2.0.**  
**	●	pricing_effective_at is non-null and defaults to now().**  
**	●	Production does not currently have:**  
**	●	provider_cache_write_usd_per_1m**  
**	●	cache_mode**  
  
**This matters because current main code in _generation_models.ts already references both concepts and currently falls back when they are absent.**  
  
**Do not assume repository type definitions and production schema are aligned. PR 1 must deliberately reconcile this.**  
  
**2.3 Current production catalog rows**  
  
**The production table currently contains these enabled rows:**  
  
|Model                   |Stored input|Stored cached|Stored output|Billing multiplier|Observed pricing state                             |  
|------------------------|-----------:|------------:|------------:|-----------------:|---------------------------------------------------|  
|`gpt-4o-mini`           |0.15        |0.075        |0.60         |2.0               |populated                                          |  
|`gpt-4.1-mini`          |0.40        |0.10         |1.60         |2.0               |populated                                          |  
|`gpt-4.1`               |2.00        |0.50         |8.00         |2.0               |populated                                          |  
|`gpt-5.6-luna`          |NULL        |NULL         |NULL         |2.0               |incomplete                                         |  
|`gpt-5.4-mini`          |0.40        |0.10         |1.60         |2.0               |populated but stale versus current official docs   |  
|`gpt-5.4-nano`          |NULL        |NULL         |NULL         |2.0               |incomplete                                         |  
|`gpt-5.6-terra`         |NULL        |NULL         |NULL         |2.0               |incomplete                                         |  
|`gpt-5.4`               |NULL        |NULL         |NULL         |2.0               |incomplete                                         |  
|`gpt-5.6-sol`           |NULL        |NULL         |NULL         |2.0               |incomplete                                         |  
|`gpt-5.5`               |5.00        |0.50         |30.00        |2.0               |populated                                          |  
|`text-embedding-3-small`|0.02        |0.02         |0.00         |2.0               |populated, but not a customer text-generation model|  
  
**Do not treat “populated” in this table as “verified current” without checking official OpenAI documentation at implementation time.**  
  
**The critical safety issue is already visible: several rows are enabled = true while their provider costs are NULL.**  
  
**2.4 Current unsafe null fallback in repository code**  
  
**Current supabase/functions/generate-story/_generation_models.ts maps provider pricing with numeric fallbacks.**  
  
**In particular, provider input/cached/output prices currently fall back to zero when absent, and cache-write pricing currently falls back to providerInput * 1.25.**  
  
**That behavior is unsafe for a billing authority.**  
  
**The target behavior is:**  
  
```text  
unknown provider price != zero  
unknown provider price => model is not billable/selectable  
```  
  
**Do not replace one guessed default with another guessed default.**  
  
**2.5 Current RLS exposure**  
  
**Production currently has this policy on generation_models:**  
  
```text  
generation_models: enabled readable  
roles: anon, authenticated  
condition: enabled = true  
```  
  
**That means enabled is currently the only DB-level visibility gate.**  
  
**Once the new eligibility fields exist, update direct read exposure so old clients cannot see a model that the Edge Function would reject.**  
  
**The Edge Function must still enforce eligibility independently; RLS is defense in depth, not the only control.**  
  
**2.6 Current duplicate pricing source**  
  
**Production also has public.model_rates.**  
  
**Current repository code still references it in at least:**  
  
**	●	supabase/functions/generate-story/index.ts**  
**	●	supabase/queries/generation_telemetry_weekly.sql**  
**	●	supabase/migrations/20260729190000_telemetry_weekly_snapshots.sql**  
  
**generate-story/index.ts has an active lookup against model_rates for telemetry cost/margin calculations.**  
  
**The existing weekly snapshot code also joins model_rates.**  
  
**This is why “one source of truth” cannot be accomplished by merely correcting generation_models. Active consumers of model_rates must be migrated before the table is retired.**  
  
**Historical migrations may continue to mention model_rates; do not rewrite migration history.**  
  
**2.7 Current telemetry evidence**  
  
**Production has both:**  
  
**	●	generation_provider_attempts**  
**	●	generation_usage_events**  
  
**generation_provider_attempts already records, among other fields:**  
  
```text  
model_name  
input_tokens  
output_tokens  
cached_input_tokens  
cache_write_input_tokens  
provider_cogs_cents  
calculated_charge_credits  
settled_charge_credits  
started_at  
provider_completed_at  
completed_at  
```  
  
**Recent settled rows show provider_cogs_cents and settled_charge_credits populated.**  
  
**generation_usage_events also has modern fields such as:**  
  
```text  
uncached_input_tokens  
cached_input_tokens  
cache_write_input_tokens  
provider_cogs_cents  
customer_revenue_cents  
margin_cents  
```  
  
**but the legacy total_model_usd field has been observed as zero while provider_cogs_cents is populated.**  
  
**Do not use total_model_usd as the new financial truth without fixing/auditing it.**  
  
**The implementation should choose one canonical internal aggregation path and prove it does not double-count the same provider call.**  
  
**2.8 Current scheduler capability**  
  
**Production currently has:**  
  
**	●	pg_cron installed (1.6.4)**  
**	●	supabase_vault installed (0.3.1)**  
**	●	pg_net available but not installed**  
  
**Current cron jobs:**  
  
```text  
telemetry-weekly-snapshot  
0 6 * * 1  
select public.capture_telemetry_weekly_snapshot();  
```  
  
**This bundle may use the existing pg_cron + Vault infrastructure, but an HTTP-triggered Edge Function schedule will require a safe invocation mechanism. If the chosen implementation uses pg_net, add it deliberately in the scheduling PR and do not hardcode secrets in SQL.**  
  
  
  
**3. Official OpenAI interfaces to use**  
  
**Verify these again during implementation. Do not rely on old memory or on rates copied from this plan.**  
  
**3.1 Model inventory**  
  
**OpenAI model inventory:**  
  
```text  
GET https://api.openai.com/v1/models  
```  
  
**Use the normal server-side OpenAI API key.**  
  
**Purpose:**  
  
**	●	discover model IDs currently available to Cathedral’s OpenAI project/account,**  
**	●	record provider availability/basic metadata.**  
  
**Do not infer pricing from /v1/models; it does not supply the token rate card.**  
  
**Official reference:**  
  
**	●	https://developers.openai.com/api/docs/models**  
**	●	OpenAI API model-list reference**  
  
**3.2 Official pricing source**  
  
**Current official model documentation exposes model-specific token pricing, e.g.:**  
  
```text  
https://developers.openai.com/api/docs/models/<model-id>  
```  
  
**and the official comparison page:**  
  
```text  
https://developers.openai.com/api/docs/models/compare  
```  
  
**These pages currently expose fields such as:**  
  
**	●	input / 1M tokens**  
**	●	cached input / 1M tokens**  
**	●	output / 1M tokens**  
**	●	cache-write pricing where applicable**  
**	●	model-specific long-context pricing rules where applicable**  
  
**Examples current as of this plan:**  
  
**	●	GPT-5.6 Sol: official model page documents $4 input, $0.40 cached, $20 output per 1M and a >272K long-context modifier.**  
**	●	GPT-5.6 Terra: $2, $0.20, $12 and a >272K modifier.**  
**	●	GPT-5.6 Luna: $0.20, $0.02, $1.20 and a >272K modifier.**  
**	●	GPT-6 Astra is already visible in current official documentation, which is exactly the class of model that must never become automatically customer-enabled.**  
  
**Do not hardcode these numbers from this document. Re-fetch and verify official pages when implementation runs.**  
  
**3.3 Provider actual costs**  
  
**OpenAI organization cost endpoint:**  
  
```text  
GET https://api.openai.com/v1/organization/costs  
```  
  
**This requires an OpenAI Admin API key.**  
  
**Store the provider’s returned daily cost buckets as the independent financial comparison point.**  
  
**3.4 Provider usage**  
  
**OpenAI organization completions usage:**  
  
```text  
GET https://api.openai.com/v1/organization/usage/completions  
```  
  
**It supports:**  
  
**	●	daily/hourly/minute buckets,**  
**	●	filtering by project_ids,**  
**	●	grouping by project_id, model, service_tier, batch, etc.,**  
**	●	provider-reported:**  
**	●	input tokens,**  
**	●	cached input tokens,**  
**	●	cache-write input tokens,**  
**	●	uncached input tokens,**  
**	●	output tokens,**  
**	●	request counts.**  
  
**Official reference:**  
**https://developers.openai.com/api/reference/python/resources/admin/subresources/organization/subresources/usage/methods/completions**  
  
**There are separate organization usage endpoints for embeddings, images, web search, etc. Audit which Cathedral OpenAI features share the same OpenAI project before calling the overall daily cost number fully reconciled.**  
  
  
  
**4. Target architecture**  
  
**The target is deliberately simple:**  
  
```text  
                         +---------------------------+  
                         | OpenAI /v1/models         |  
                         | "what exists?"            |  
                         +-------------+-------------+  
                                       |  
                                       v  
+----------------------+      +-------------------------------+  
| Official OpenAI      |----->| openai pricing observations   |  
| model/pricing docs   |      | append-only audit/history     |  
| "what is the rate?"  |      +---------------+---------------+  
+----------------------+                      |  
                                               | validated promotion  
                                               v  
                                  +---------------------------+  
                                  | generation_models         |  
                                  | LIVE runtime source       |  
                                  | provider rates            |  
                                  | operator enablement       |  
                                  | provider availability     |  
                                  +------------+--------------+  
                                               |  
                      +------------------------+----------------------+  
                      |                                               |  
                      v                                               v  
            model picker eligibility                       request-time billing  
                                                              snapshot + settle  
OpenAI Admin Costs/Usage APIs  
            |  
            v  
+-------------------------------+  
| provider daily actuals        |  
| independent reconciliation    |  
+---------------+---------------+  
                |  
                v  
+----------------------------------------------------------+  
| compare OpenAI actual vs Cathedral recorded COGS         |  
| vs customer settled charge                               |  
+----------------------------------------------------------+  
```  
  
**Single source of truth means**  
  
**generation_models is the only table whose current provider rates may feed a live customer billing calculation.**  
  
**The following are not competing live pricing sources:**  
  
**	●	openai_pricing_observations: evidence/history of official checks.**  
**	●	historical request pricing snapshots / provider_cogs_cents: immutable historical facts.**  
**	●	openai_daily_costs: provider actual spend after the fact.**  
**	●	openai_daily_completion_usage: provider usage after the fact.**  
  
**Those tables exist to audit the live source, not replace it at request time.**  
  
  
  
**5. Critical business/safety invariants**  
  
**These are acceptance requirements, not suggestions.**  
  
**5.1 New model default**  
  
**If OpenAI starts returning:**  
  
```text  
gpt-6-astra  
```  
  
**the initial discovered state must be equivalent to:**  
  
```text  
provider_available = true  
enabled = false  
model_kind = unknown (or deliberately classified)  
pricing_state = unverified  
provider_input_usd_per_1m = NULL  
provider_cached_input_usd_per_1m = NULL  
provider_output_usd_per_1m = NULL  
picker_eligible = false  
```  
  
**Even if the price checker successfully finds Astra’s official price later:**  
  
```text  
enabled must remain false  
```  
  
**Discovery and pricing must never silently grant product enablement.**  
  
**5.2 Null pricing rule**  
  
**For a customer text-generation model, any required pricing field being NULL means the model is not selectable/billable.**  
  
**Unknown must never become zero through a mapper.**  
  
**5.3 Backend enforcement**  
  
**Hiding a model in the picker is not sufficient.**  
  
**A direct request using an ineligible selectedModelId must fail before:**  
  
**	●	provider dispatch,**  
**	●	customer credit mutation,**  
**	●	usage settlement.**  
  
**Use a deterministic error code such as:**  
  
```text  
model_unavailable_or_unpriced  
```  
  
**Do not silently substitute another model.**  
  
**5.4 Parser failure rule**  
  
**Daily official-page checking is allowed to update prices automatically only after complete validation.**  
  
**If today’s page fetch/parsing fails:**  
  
**	●	record the failure,**  
**	●	do not erase the known-good rate,**  
**	●	do not write zeros,**  
**	●	do not write partial rates,**  
**	●	do not automatically remove all existing models from the app solely because the documentation page format changed.**  
  
**This is important operationally. A documentation markup change must not take Cathedral down.**  
  
**5.5 Price-change rule**  
  
**For an already offered model:**  
  
```text  
valid complete official observation  
        ->  
atomic current-rate update in generation_models  
        ->  
future requests use new rate  
```  
  
**In-flight/completed requests keep their captured historical settlement facts.**  
  
**5.6 Customer multiplier**  
  
**The existing billing_multiplier remains Cathedral’s markup control.**  
  
**This bundle does not change 2.0 or invent a new margin policy.**  
  
**5.7 No retroactive rebilling**  
  
**Admin reconciliation may discover that Cathedral undercharged in the past.**  
  
**Record the discrepancy.**  
  
**Do not mutate old customer ledger entries and do not charge users retroactively.**  
  
  
  
**6. PR sequence**  
  
**Use five separate PRs.**  
  
**This is intentionally more conservative than a single rewrite.**  
  
**Do not start a later PR until the previous PR is reviewed and its assumptions are stable.**  
  
  
  
**PR 1 — Reconcile schema, correct fail-open billing behavior, and enforce priced-model eligibility**  
  
**Goal**  
  
**Make the existing system safe before adding any automatic discovery or scraping.**  
  
**Expected primary files**  
  
**Likely:**  
  
```text  
supabase/migrations/<new>_generation_model_pricing_safety.sql  
supabase/functions/generate-story/_generation_models.ts  
supabase/functions/generate-story/pricing_test.ts  
supabase/functions/generate-story/index.ts  
supabase/functions/generation-models/index.ts  
supabase/functions/generation-models/*test*  
supabase/functions/_shared/billable-llm.ts  
supabase/functions/_shared/billable-llm_test.ts  
supabase/functions/_shared/direct-billing.ts  
relevant coherence/run-outline tests  
```  
  
**Do not touch unrelated prompt or story-generation logic.**  
  
**6.1 Schema changes**  
  
**Before writing migration SQL, compare current main migration history against production. We already verified the current production mismatch:**  
  
**	●	main TS expects cache-write pricing/cache mode concepts,**  
**	●	production lacks those columns.**  
  
**Add only the minimum forward schema required.**  
  
**Recommended additions to generation_models:**  
  
```text  
provider_available boolean  
provider_first_seen_at timestamptz  
provider_last_seen_at timestamptz  
provider_created_at timestamptz  
provider_owned_by text  
model_kind text  
pricing_state text  
pricing_verified_at timestamptz  
pricing_source_url text  
pricing_source_hash text  
pricing_parser_version text  
provider_cache_write_usd_per_1m numeric  
cache_mode text  
cache_write_pricing_required boolean  
```  
  
**Use CHECK constraints for narrow state fields rather than creating unnecessary application enums.**  
  
**Suggested model_kind values:**  
  
```text  
text_generation  
embedding  
image  
audio  
moderation  
unknown  
```  
  
**Suggested pricing_state:**  
  
```text  
unverified  
verified  
needs_review  
```  
  
**Suggested cache_mode should align with the currently used code vocabulary:**  
  
```text  
none  
implicit  
explicit  
```  
  
**Do not make provider rate columns globally NOT NULL because newly discovered models must be allowed to exist while unpriced.**  
  
**6.2 Bootstrap existing rows safely**  
  
**Do not accidentally hide every existing model during the migration.**  
  
**For current known rows:**  
  
**	●	classify actual text models as text_generation,**  
**	●	classify text-embedding-3-small as embedding,**  
**	●	preserve current operator enabled,**  
**	●	bootstrap provider availability conservatively for existing working catalog rows, then allow PR 2’s first provider sync to correct it,**  
**	●	only mark pricing_state = verified after re-checking the official OpenAI page in the implementation PR.**  
  
**If a current rate cannot be verified:**  
  
**	●	leave/put it in unverified or needs_review,**  
**	●	make it non-selectable.**  
  
**6.3 Fix null mapping**  
  
**In _generation_models.ts:**  
  
**Current unsafe concept:**  
  
```text  
NULL -> toNumber(..., 0)  
```  
  
**Replace it with a nullable parser, e.g.:**  
  
```text  
function toNullableNumber(value: unknown): number | null  
```  
  
**Provider pricing fields should remain nullable in the raw catalog representation.**  
  
**Introduce a validated/billable representation or type guard so snapshotPricing() cannot accept incomplete pricing.**  
  
**Acceptable pattern:**  
  
```text  
GenerationModel              // raw catalog row; provider prices may be null  
PricedGenerationModel        // required rates are known  
isPricedGenerationModel()  
assertBillableGenerationModel()  
```  
  
**Do not let snapshotPricing() contain ?? 0 provider-rate fallbacks.**  
  
**6.4 Remove generic cache-write guess**  
  
**Current main contains a fallback equivalent to:**  
  
```text  
provider cache write = provider input * 1.25  
```  
  
**That is not an acceptable universal billing default.**  
  
**Store an explicitly verified cache-write rate when the model can produce billable cache-write tokens.**  
  
**If cache-write pricing is not applicable to a model, represent that separately. Do not overload NULL to mean both “unknown” and “not applicable.”**  
  
**If a provider response reports cache-write tokens for a model whose required cache-write price is unavailable:**  
  
**	●	fail settlement safely / surface a billing configuration error,**  
**	●	do not price those tokens at zero.**  
  
**6.5 Canonical eligibility helper**  
  
**Create one backend concept for “customer-selectable generation model.”**  
  
**A text-generation model is eligible only if:**  
  
```text  
enabled = true  
provider_available = true  
model_kind = text_generation  
pricing_state = verified  
pricing_verified_at is not null  
provider_input_usd_per_1m is not null  
provider_cached_input_usd_per_1m is not null  
provider_output_usd_per_1m is not null  
billing_multiplier > 0  
provider_model is non-empty  
and, when cache_write_pricing_required = true:  
    provider_cache_write_usd_per_1m is not null  
```  
  
**Use the same rule in:**  
  
**	●	listEnabledModels() / model picker response,**  
**	●	getEnabledModelById() or its replacement,**  
**	●	provider-model resolution used for billable requests,**  
**	●	generate-story,**  
**	●	outline generation,**  
**	●	coherence-check,**  
**	●	run-outline,**  
**	●	any other customer-billable text generation path.**  
  
**Do not use the raw catalog getter where a billable/selectable getter is required.**  
  
**6.6 RLS defense in depth**  
  
**Replace the current direct “enabled readable” policy with a policy that does not expose clearly ineligible customer rows to normal app users.**  
  
**Service-role/internal syncs may still access all rows.**  
  
**Do not make RLS the only eligibility check.**  
  
**6.7 Picker behavior**  
  
**generation-models must return only eligible text_generation models.**  
  
**text-embedding-3-small must not appear in the text generation model picker.**  
  
**No Swift-side pricing filter is required if the backend response is correct.**  
  
**Avoid changing picker UI or layout.**  
  
**6.8 Current price correction**  
  
**During PR 1, re-check each currently intended model on official OpenAI documentation.**  
  
**Update the stored rates by forward migration only.**  
  
**Do not copy today’s rates blindly from this plan.**  
  
**The PR description must include:**  
  
|model|old input|verified input|old cached|verified cached|old cache-write|verified cache-write|old output|verified output|source URL|verified at|eligible after|  
|-----|--------:|-------------:|---------:|--------------:|--------------:|-------------------:|---------:|--------------:|----------|-----------|--------------|  
  
**Unknown means:**  
  
**	●	store NULL where applicable,**  
**	●	do not mark verified,**  
**	●	do not expose model.**  
  
**6.9 Long-context price modifiers**  
  
**Current OpenAI docs document higher pricing above specific input thresholds for some newer models.**  
  
**Do not build an open-ended pricing rules engine in PR 1.**  
  
**Instead:**  
  
**	1.	Audit Cathedral’s actual maximum possible input size on every customer-billable path.**  
**	2.	If existing server payload/context limits make the provider threshold unreachable, document that and defer modifier support.**  
**	3.	If Cathedral can currently exceed a threshold:**  
**	●	either implement the small explicit rule required for those models,**  
**	●	or reject requests above the safe threshold until correct pricing support exists.**  
  
**Never knowingly allow a request into a provider pricing tier Cathedral cannot calculate.**  
  
**6.10 PR 1 tests**  
  
**At minimum:**  
  
```text  
priced + verified + available + enabled text model -> picker includes  
NULL input -> picker excludes  
NULL cached -> picker excludes  
NULL output -> picker excludes  
cache-write required + NULL cache-write -> picker excludes  
pricing unverified -> picker excludes  
provider unavailable -> picker excludes  
operator disabled -> picker excludes  
embedding -> picker excludes  
direct request for ineligible model -> rejected  
ineligible direct request -> zero provider dispatch  
ineligible direct request -> zero credit mutation  
mapModelRow preserves NULL pricing  
snapshotPricing cannot produce zero COGS from unknown price  
corrected current model rates feed settlement  
existing idempotent billing semantics stay green  
```  
  
**PR 1 hard boundary**  
  
**Do not:**  
  
**	●	add /v1/models sync yet,**  
**	●	add pricing-page scraping yet,**  
**	●	add Admin Costs yet,**  
**	●	remove model_rates yet,**  
**	●	alter prompts,**  
**	●	alter outline planning,**  
**	●	alter scene memory,**  
**	●	alter Run All lifecycle,**  
**	●	alter data durability,**  
**	●	change multiplier policy,**  
**	●	merge/deploy/TestFlight.**  
  
  
  
**PR 2 — OpenAI model inventory synchronization**  
  
**Goal**  
  
**Automatically know what OpenAI models Cathedral’s API credentials can currently access, without automatically selling them.**  
  
**Edge Function**  
  
**Suggested:**  
  
```text  
supabase/functions/sync-openai-model-catalog/  
```  
  
**Use the existing normal server-side OPENAI_API_KEY.**  
  
**Call:**  
  
```text  
GET /v1/models  
```  
  
**6.11 Sync behavior**  
  
**For each complete provider response:**  
  
**Existing row seen**  
  
**Update provider facts only:**  
  
```text  
provider_available = true  
provider_last_seen_at = now  
provider_created_at = provider value if available  
provider_owned_by = provider value if available  
```  
  
**Preserve:**  
  
```text  
enabled  
display_name  
description  
pricing fields  
pricing_state  
pricing_verified_at  
sort_order  
```  
  
**New provider model**  
  
**Insert:**  
  
```text  
provider = openai  
provider_model = exact provider ID  
provider_available = true  
provider_first_seen_at = now  
provider_last_seen_at = now  
provider metadata  
enabled = false  
model_kind = unknown  
pricing_state = unverified  
pricing fields = NULL  
pricing_verified_at = NULL  
```  
  
**Do not guess product suitability from an ID prefix.**  
  
**6.12 Successful full-response rule**  
  
**Only mark previously known provider models unavailable after:**  
  
**	1.	/v1/models returned successfully,**  
**	2.	the full payload was parsed and validated,**  
**	3.	the reconciliation transaction is ready.**  
  
**If the request fails or the payload is malformed:**  
  
```text  
do not mark any existing model unavailable  
```  
  
**Never let an OpenAI transient error empty the picker.**  
  
**6.13 Do not delete missing models**  
  
**If a previously known model disappears:**  
  
```text  
provider_available = false  
```  
  
**Keep its row and pricing history.**  
  
**Historical generation references must continue to resolve.**  
  
**6.14 Sync-run table**  
  
**Add operator-only table, e.g.:**  
  
```text  
openai_model_sync_runs  
```  
  
**Fields:**  
  
```text  
id uuid  
started_at  
completed_at  
status  
models_seen  
models_inserted  
models_marked_available  
models_marked_unavailable  
error_code  
sanitized_error  
```  
  
**No keys/Authorization headers/raw secrets.**  
  
**6.15 Scheduling**  
  
**Do not schedule until manual function tests pass.**  
  
**Recommended final frequency:**  
  
```text  
daily around 04:05 UTC  
```  
  
**Discovery does not need to be frequent because new models remain disabled.**  
  
**PR 2 acceptance example**  
  
**When OpenAI returns gpt-6-astra:**  
  
```text  
row exists  
provider_available = true  
enabled = false  
pricing_state = unverified  
picker excludes  
direct request rejects  
```  
  
**PR 2 boundary**  
  
**Do not:**  
  
**	●	scrape pricing yet,**  
**	●	change current verified rates except for PR 1 fixes,**  
**	●	auto-enable any discovered model,**  
**	●	modify customer billing policy,**  
**	●	merge/deploy without review.**  
  
  
  
**PR 3 — Official pricing-page observation and safe automatic promotion**  
  
**Goal**  
  
**Check official OpenAI pricing/model pages daily and keep current provider rates updated automatically without turning a documentation-page parser into a single point of failure.**  
  
**This is the highest-risk PR in the bundle. Keep it isolated.**  
  
**Edge Function**  
  
**Suggested:**  
  
```text  
supabase/functions/sync-openai-pricing/  
```  
  
**No OpenAI API key should be needed merely to fetch public official documentation.**  
  
**Only allow HTTPS sources under the official OpenAI documentation domains selected in implementation.**  
  
**6.16 Pricing observation table**  
  
**Create:**  
  
```text  
openai_pricing_observations  
```  
  
**Suggested fields:**  
  
```text  
id uuid primary key  
provider_model text  
observed_at timestamptz  
source_url text  
source_hash text  
parser_version text  
http_status integer  
status text  
  verified  
  incomplete  
  conflict  
  fetch_failed  
  unsupported  
input_usd_per_1m numeric null  
cached_input_usd_per_1m numeric null  
cache_write_usd_per_1m numeric null  
output_usd_per_1m numeric null  
long_context_threshold_tokens integer null  
long_context_input_multiplier numeric null  
long_context_output_multiplier numeric null  
error_code text null  
sanitized_error text null  
promoted_at timestamptz null  
created_at timestamptz  
```  
  
**Do not store the full OpenAI documentation page unless there is a specific need.**  
  
**A source URL + SHA-256 hash + parsed fields + parser version is enough for auditability.**  
  
**6.17 Source strategy**  
  
**Primary source should be the model’s official detail page where one exists:**  
  
```text  
https://developers.openai.com/api/docs/models/<provider_model>  
```  
  
**The global compare/pricing page may be used as a secondary cross-check.**  
  
**Do not scrape search-engine results, blogs, cached snippets, Reddit, or third-party rate cards.**  
  
**6.18 Parser safety**  
  
**Do not use a broad regex that grabs the first dollar amounts on the page.**  
  
**The parser must:**  
  
**	1.	confirm the page identifies the expected model,**  
**	2.	locate the model’s Pricing / Text tokens section,**  
**	3.	extract labeled rate dimensions,**  
**	4.	distinguish per-1M rates from unrelated dollar amounts,**  
**	5.	detect documented cache-write rules,**  
**	6.	detect documented long-context modifiers when present,**  
**	7.	validate finite numeric values,**  
**	8.	reject partial/ambiguous parses.**  
  
**Do not infer missing output pricing.**  
  
**Do not infer cache-write pricing from an unrelated model family.**  
  
**6.19 Source disagreement**  
  
**If two official sources disagree materially:**  
  
```text  
status = conflict  
do not promote  
```  
  
**Record enough metadata to diagnose it.**  
  
**This is safer than choosing whichever value is cheaper or newer-looking.**  
  
**6.20 Auto-promotion rule**  
  
**A verified observation may update generation_models for that exact provider_model in a single transaction.**  
  
**Update:**  
  
```text  
provider_input_usd_per_1m  
provider_cached_input_usd_per_1m  
provider_cache_write_usd_per_1m as applicable  
provider_output_usd_per_1m  
pricing_state = verified  
pricing_verified_at = observation timestamp  
pricing_source_url  
pricing_source_hash  
pricing_parser_version  
pricing_effective_at  
```  
  
**Do not change:**  
  
```text  
enabled  
sort_order  
display_name  
product description  
billing_multiplier  
```  
  
**Thus a newly discovered Astra can receive a correct automated rate card and still remain operator-disabled.**  
  
**6.21 Existing-model parser failure**  
  
**If an existing offered model had a known-good verified rate yesterday and today’s page parser fails:**  
  
```text  
keep yesterday's rate  
record failed observation  
do not null it  
do not zero it  
do not auto-disable solely because the page markup changed  
```  
  
**This is an explicit reliability requirement.**  
  
**6.22 Valid price changes**  
  
**If a complete official observation clearly changes a currently verified rate:**  
  
**	●	append observation,**  
**	●	promote atomically,**  
**	●	future requests use the new rate,**  
**	●	historical settled requests remain unchanged.**  
  
**Add a sanity guard for obvious parser corruption, not ordinary provider price changes. For example, reject non-finite/negative values and absurd magnitude jumps. Do not use a tight arbitrary percentage threshold that prevents legitimate OpenAI price changes.**  
  
**6.23 Pricing history**  
  
**Do not overwrite or delete prior observations.**  
  
**generation_models is current state; observations are audit history.**  
  
**6.24 Schedule**  
  
**Recommended:**  
  
```text  
daily around 04:20 UTC  
```  
  
**Run after model inventory sync.**  
  
**PR 3 tests**  
  
**Use small synthetic official-page fixtures; do not commit entire downloaded pages.**  
  
**Cases:**  
  
```text  
exact model page -> complete verified parse  
wrong model page -> reject  
missing output price -> incomplete  
duplicate ambiguous price labels -> incomplete  
official source disagreement -> conflict  
HTTP failure -> fetch_failed  
invalid number -> reject  
existing good price + parser failure -> generation_models unchanged  
valid changed price -> atomically promoted  
new disabled model + valid price -> still disabled  
price update -> billing_multiplier unchanged  
page content hash persisted  
```  
  
**PR 3 boundary**  
  
**Do not:**  
  
**	●	auto-enable newly priced models,**  
**	●	alter prompts/generation behavior,**  
**	●	use page scraping to rewrite historical settlements,**  
**	●	call external third-party pricing services,**  
**	●	make parser failure clear current production rates.**  
  
  
  
**PR 4 — OpenAI Admin Costs/Usage ingestion and daily reconciliation**  
  
**Goal**  
  
**Record provider-side financial truth independently from Cathedral’s own billing calculations.**  
  
**Secrets/configuration**  
  
**Required server-side environment secrets/config:**  
  
```text  
OPENAI_ADMIN_KEY  
OPENAI_PROJECT_ID  
```  
  
**OPENAI_ADMIN_KEY is not the normal generation API key.**  
  
**If OPENAI_PROJECT_ID is missing:**  
  
```text  
fail closed  
```  
  
**Do not ingest organization-wide cost and label it as Cathedral project cost.**  
  
**Never expose either value to iOS.**  
  
**Edge Function**  
  
**Suggested:**  
  
```text  
supabase/functions/sync-openai-admin-usage/  
```  
  
**It may perform both Costs and completions Usage ingestion, or share a common internal client.**  
  
**6.25 Daily costs table**  
  
**Create operator-only:**  
  
```text  
openai_daily_costs  
```  
  
**Suggested fields:**  
  
```text  
id uuid  
bucket_start timestamptz  
bucket_end timestamptz  
bucket_date date  
project_id text  
line_item text  
amount_value numeric(18,9)  
amount_currency text  
quantity numeric null  
quantity_unit text null  
synced_at timestamptz  
source text default 'openai_organization_costs_api'  
source_result_hash text null  
raw_metadata jsonb null  
```  
  
**Use exact OpenAI result identity fields to build an idempotent unique constraint.**  
  
**Do not round provider cost to cents internally.**  
  
**UPSERT revisions.**  
  
**6.26 Completions usage table**  
  
**Create operator-only:**  
  
```text  
openai_daily_completion_usage  
```  
  
**Suggested fields:**  
  
```text  
id  
bucket_start  
bucket_end  
bucket_date  
project_id  
model  
service_tier  
batch  
num_model_requests  
input_tokens  
input_uncached_tokens  
input_cached_tokens  
input_cache_write_tokens  
output_tokens  
synced_at  
```  
  
**Use null-safe uniqueness over the actual grouping dimensions.**  
  
**Call:**  
  
```text  
/v1/organization/usage/completions  
```  
  
**with:**  
  
```text  
bucket_width=1d  
project_ids=[OPENAI_PROJECT_ID]  
group_by=[project_id, model, service_tier, batch]  
```  
  
**Handle pagination using has_more / next_page.**  
  
**6.27 Other OpenAI usage categories**  
  
**Audit all Cathedral OpenAI provider paths.**  
  
**The repo currently includes at least:**  
  
**	●	text generation,**  
**	●	text embeddings,**  
**	●	image/cover billing code.**  
  
**If those share the same OpenAI project, the total Costs endpoint includes spend outside completions.**  
  
**Do one of:**  
  
**	1.	ingest the matching provider usage endpoints too, or**  
**	2.	explicitly mark reconciliation coverage as partial.**  
  
**Do not claim “OpenAI total equals our text-generation COGS” if the provider project also contains embedding/image spend.**  
  
**6.28 Sync window**  
  
**Recommended schedule:**  
  
```text  
every 6 hours  
```  
  
**Each run refreshes:**  
  
```text  
current UTC day + previous 7 UTC days  
```  
  
**Reason:**  
  
**	●	current day is partial,**  
**	●	provider cost data can revise,**  
**	●	rolling UPSERT converges without a repair job.**  
  
**Do not treat today’s row as final.**  
  
**6.29 Reconciliation view**  
  
**Create an operator-only SQL view, e.g.:**  
  
```text  
openai_daily_billing_reconciliation  
```  
  
**For each UTC day include, where scopes are comparable:**  
  
```text  
date  
openai_actual_cost_usd  
cathedral_recorded_provider_cogs_usd  
cathedral_settled_customer_credits  
cathedral_settled_customer_revenue_usd  
actual_margin_usd  
actual_margin_pct  
provider_cost_variance_usd  
provider_cost_variance_pct  
cathedral_provider_calls  
cathedral_input_tokens  
cathedral_cached_input_tokens  
cathedral_cache_write_tokens  
cathedral_output_tokens  
openai_provider_requests  
openai_input_tokens  
openai_cached_input_tokens  
openai_cache_write_tokens  
openai_output_tokens  
input_token_variance  
cached_token_variance  
cache_write_token_variance  
output_token_variance  
coverage_status  
```  
  
**6.30 Internal telemetry source**  
  
**Do not aggregate both generation_provider_attempts and generation_usage_events as if they were independent calls.**  
  
**Audit the one-to-one linkage.**  
  
**Prefer the table that most directly represents a settled provider dispatch.**  
  
**Current production evidence suggests generation_provider_attempts is a strong source for:**  
  
**	●	provider call count,**  
**	●	token counts,**  
**	●	provider_cogs_cents,**  
**	●	settled_charge_credits.**  
  
**Use generation_usage_events only where it adds non-duplicated information or after proving canonical mapping.**  
  
**Do not use legacy total_model_usd = 0 rows as authoritative COGS.**  
  
**6.31 Historical meaning**  
  
**For a prior day:**  
  
```text  
Cathedral recorded provider COGS  
```  
  
**means what Cathedral calculated at request settlement time.**  
  
**Do not recalculate the old day from today’s generation_models price.**  
  
**That variance against OpenAI actual cost is exactly what this audit is supposed to expose.**  
  
**6.32 No automatic customer correction**  
  
**Reconciliation is read/audit only.**  
  
**Do not:**  
  
**	●	debit customer credits,**  
**	●	refund credits,**  
**	●	change old settled_charge_credits,**  
**	●	update old provider_cogs_cents.**  
  
**PR 4 tests**  
  
**At minimum:**  
  
```text  
Admin key absent -> fail before request  
project ID absent -> fail closed  
cost pagination  
usage pagination  
UTC bucket boundaries  
decimal precision  
re-running same window -> UPSERT, no duplicates  
revised provider bucket -> updated  
current day refreshes  
provider error -> existing data preserved  
Admin secret never persisted/logged  
usage grouped by model persists  
cached/cache-write tokens persist  
reconciliation variance calculations correct  
historical current-rate changes do not rewrite old internal COGS  
reconciliation causes zero credit mutations  
```  
  
  
  
**PR 5 — Remove legacy live pricing authority and finish telemetry cleanup**  
  
**Goal**  
  
**Only after PRs 1–4 are proven, remove model_rates as an active pricing source and make the single-source design explicit.**  
  
**6.33 Audit every active reference**  
  
**Search current main for:**  
  
```text  
model_rates  
input_per_1k_usd  
output_per_1k_usd  
premium_markup_pct  
total_model_usd  
model_input_usd  
model_output_usd  
```  
  
**Classify each match:**  
  
```text  
live billing  
live telemetry  
reporting  
test  
documentation  
historical migration  
```  
  
**Do not modify historical migrations merely because they contain old table names.**  
  
**6.34 Migrate active model_rates consumers**  
  
**Known current active locations include:**  
  
```text  
supabase/functions/generate-story/index.ts  
supabase/queries/generation_telemetry_weekly.sql  
weekly telemetry snapshot SQL  
```  
  
**Modern telemetry should use already-settled facts such as:**  
  
```text  
provider_cogs_cents  
customer_revenue_cents  
margin_cents  
```  
  
**or the immutable request pricing snapshot, not a second current rate lookup.**  
  
**6.35 total_model_usd**  
  
**Current production has shown total_model_usd = 0 while modern provider_cogs_cents is populated.**  
  
**Do not backfill history blindly.**  
  
**For new reporting:**  
  
```text  
provider COGS = canonical modern COGS field  
```  
  
**Mark legacy columns as deprecated in code/docs if retaining them for compatibility.**  
  
**6.36 Drop model_rates only when safe**  
  
**Required before dropping:**  
  
```text  
repo search shows zero active runtime consumers  
fresh Supabase reset succeeds  
all telemetry tests pass  
weekly snapshot capture works without model_rates  
production migration ordering is valid  
```  
  
**Then drop it with a new forward migration.**  
  
**Do not edit the migration that originally created it.**  
  
**If the physical drop introduces avoidable migration/reset risk, remove all runtime dependence first and use a separate tiny cleanup PR to drop it. Runtime single-source behavior matters more than forcing a drop into a risky diff.**  
  
**6.37 Catalog health view**  
  
**Add an operator-only diagnostic view:**  
  
```text  
generation_model_catalog_health  
```  
  
**Suggested columns:**  
  
```text  
id  
provider_model  
display_name  
model_kind  
provider_available  
enabled  
picker_eligible  
pricing_state  
pricing_verified_at  
pricing_source_url  
provider_input_usd_per_1m  
provider_cached_input_usd_per_1m  
provider_cache_write_usd_per_1m  
provider_output_usd_per_1m  
billing_multiplier  
provider_last_seen_at  
reason_not_selectable  
```  
  
**Example reasons:**  
  
```text  
operator_disabled  
provider_unavailable  
wrong_model_kind  
pricing_unverified  
missing_input_price  
missing_cached_input_price  
missing_output_price  
missing_cache_write_price  
invalid_multiplier  
```  
  
**This is operator telemetry, not a customer API.**  
  
  
  
**7. Scheduler implementation plan**  
  
**Do not add all scheduling infrastructure in PR 1.**  
  
**Production currently has pg_cron and Supabase Vault installed. pg_net is available but not installed.**  
  
**Preferred final pattern if the agent confirms it is supported cleanly:**  
  
```text  
pg_cron  
   |  
   v  
pg_net HTTP request  
   |  
   v  
internal Edge Function  
```  
  
**The invocation credential must come from Vault or another server-only secret mechanism.**  
  
**Do not place:**  
  
```text  
SUPABASE_SERVICE_ROLE_KEY  
OPENAI_API_KEY  
OPENAI_ADMIN_KEY  
internal scheduler secret  
```  
  
**inside migration text.**  
  
**Suggested final schedules:**  
  
```text  
04:05 UTC daily        sync-openai-model-catalog  
04:20 UTC daily        sync-openai-pricing  
every 6 hours          sync-openai-admin-usage  
06:00 UTC Monday       existing telemetry-weekly-snapshot (leave intact unless PR 5 updates internals)  
```  
  
**If pg_net installation or Edge scheduling creates unnecessary risk, stop and document the manual/supported scheduler setup rather than improvising secrets into SQL.**  
  
**Manual invocation must work before cron wiring is enabled.**  
  
  
  
**8. Deployment sequencing**  
  
**This is important. Do not deploy the entire bundle as one event.**  
  
**Phase A — safety first**  
  
**PR 1 reviewed:**  
  
**	●	null pricing cannot bill,**  
**	●	incomplete models disappear from picker,**  
**	●	current rates corrected,**  
**	●	no generation behavior changes.**  
  
**Only then deploy PR 1.**  
  
**Smoke check:**  
  
```text  
generation-models returns only eligible text models  
known generation succeeds  
unpriced model direct request fails  
credits settle correctly  
```  
  
**Phase B — discovery**  
  
**Deploy PR 2 without cron first.**  
  
**Run model sync manually.**  
  
**Inspect inserted/updated rows.**  
  
**Confirm new models are disabled.**  
  
**Only then enable daily schedule.**  
  
**Phase C — price observer**  
  
**Deploy PR 3 without cron first.**  
  
**Run against known models.**  
  
**Inspect observations.**  
  
**Compare parsed results manually to official OpenAI pages.**  
  
**Test one synthetic price-change fixture.**  
  
**Only then enable daily promotion schedule.**  
  
**Phase D — Admin reconciliation**  
  
**Configure:**  
  
```text  
OPENAI_ADMIN_KEY  
OPENAI_PROJECT_ID  
```  
  
**Run a 7-day manual backfill.**  
  
**Compare the returned OpenAI daily total to the OpenAI dashboard.**  
  
**Then enable six-hour schedule.**  
  
**Phase E — cleanup**  
  
**Only after several successful production syncs:**  
  
**	●	migrate final telemetry consumers,**  
**	●	retire/drop model_rates.**  
  
  
  
**9. Rollback characteristics**  
  
**Each PR must be independently reversible in behavior.**  
  
**PR 1**  
  
**If a pricing eligibility regression occurs:**  
  
**	●	disable affected model rows, or**  
**	●	revert function deployment.**  
**	●	Do not restore “NULL => zero.”**  
  
**PR 2**  
  
**Disable cron / sync function.**  
**Catalog rows remain harmless because new ones are disabled.**  
  
**PR 3**  
  
**Disable pricing sync.**  
**generation_models retains last known valid rates.**  
  
**Do not delete pricing observations.**  
  
**PR 4**  
  
**Disable Admin sync.**  
**Customer billing is unaffected.**  
  
**Historical provider daily records remain.**  
  
**PR 5**  
  
**Do not drop model_rates until all consumers are proven gone.**  
  
  
  
**10. Explicit out-of-scope boundaries**  
  
**This bundle must not become a broad CathedralOS refactor.**  
  
**Do not change:**  
  
**	●	outline-from-recipe architecture,**  
**	●	suggestion worker lifecycle,**  
**	●	provider-call count for outline generation,**  
**	●	enrichment/allocation/expansion logic,**  
**	●	prompt text,**  
**	●	section contracts,**  
**	●	story material generation,**  
**	●	scene memory,**  
**	●	RAG behavior,**  
**	●	Run All continuation,**  
**	●	SwiftData/data durability,**  
**	●	Accept All behavior,**  
**	●	import/export schema,**  
**	●	StoreKit,**  
**	●	subscription logic,**  
**	●	credit value ($0.01 convention),**  
**	●	billing multiplier unless separately requested,**  
**	●	user-facing model-picker design,**  
**	●	model quality ranking,**  
**	●	generation length/container semantics,**  
**	●	provider timeouts unless a test proves directly necessary,**  
**	●	iOS navigation/UI beyond contract compatibility,**  
**	●	historical settled charges.**  
  
**Do not merge adjacent “cleanup” simply because a file is open.**  
  
**No unrelated formatting churn.**  
  
**No migration-history edits.**  
  
**No TestFlight.**  
  
**No production deployment unless Kevin separately requests it.**  
  
  
  
**11. Full acceptance scenario**  
  
**Before the bundle is considered complete, automate or manually demonstrate this sequence.**  
  
**Scenario A — existing correctly configured model**  
  
```text  
provider lists model  
pricing is verified  
enabled = true  
```  
  
**Expected:**  
  
```text  
picker includes  
direct request succeeds  
request snapshots correct current pricing  
provider call settles  
customer charge uses configured multiplier  
```  
  
**Scenario B — Astra appears tomorrow**  
  
**OpenAI /v1/models first reports:**  
  
```text  
gpt-6-astra  
```  
  
**Expected immediately:**  
  
```text  
catalog row inserted  
provider_available = true  
enabled = false  
pricing unverified initially  
picker excludes  
direct request rejects  
```  
  
**Scenario C — daily price checker finds Astra’s official price**  
  
**Expected:**  
  
```text  
pricing observation inserted  
complete validated rate promoted to generation_models  
pricing verified  
enabled remains false  
picker still excludes  
direct request still rejects  
```  
  
**Scenario D — operator enables Astra**  
  
**After intentional product decision:**  
  
```text  
enabled = true  
```  
  
**Expected:**  
  
```text  
picker includes without requiring an iOS release  
direct request can resolve it  
billing uses verified current rate x multiplier  
```  
  
**Scenario E — provider removes Astra**  
  
**Successful full /v1/models sync no longer includes it.**  
  
**Expected:**  
  
```text  
provider_available = false  
picker removes immediately  
new direct request rejects  
historical generations remain intact  
pricing history retained  
```  
  
**Scenario F — OpenAI changes an existing model price**  
  
**Daily official page check parses a complete new rate.**  
  
**Expected:**  
  
```text  
new observation retained  
generation_models updated atomically  
future requests use new rate  
older settled requests unchanged  
```  
  
**Scenario G — OpenAI changes docs markup**  
  
**Parser cannot identify rates safely.**  
  
**Expected:**  
  
```text  
failed/incomplete observation  
known-good generation_models rates unchanged  
no prices become zero  
no mass picker outage solely from parser failure  
```  
  
**Scenario H — actual bill differs**  
  
**OpenAI Costs API shows:**  
  
```text  
$X actual provider cost  
```  
  
**Cathedral internal settled attempts show:**  
  
```text  
$Y recorded provider COGS  
$Z customer revenue  
```  
  
**Expected:**  
  
```text  
daily reconciliation exposes X/Y/Z and variance  
no customer ledger mutation  
```  
  
  
  
**12. Agent validation requirements per PR**  
  
**Every PR report must include:**  
  
```text  
base SHA  
head SHA  
branch  
exact files changed  
exact migrations added  
schema changes  
behavior changed  
behavior explicitly not changed  
tests run and counts  
deno check  
git diff --check  
CI status  
local Supabase reset/migration result  
production assumptions that were re-verified  
manual post-merge configuration required  
remaining model_rates active references  
remaining hardcoded production provider prices  
known unresolved pricing dimensions  
```  
  
**For migration PRs:**  
  
```text  
supabase db reset  
```  
  
**or the repo’s equivalent clean migration gate must pass.**  
  
**If clean reset is blocked by an unrelated pre-existing migration defect:**  
  
**	●	identify it precisely,**  
**	●	do not silently edit old migrations,**  
**	●	use the narrowest honest gate possible,**  
**	●	report the limitation.**  
  
  
  
**13. Required test philosophy**  
  
**Tests must prove safety, not merely string presence.**  
  
**Good tests:**  
  
```text  
unknown price cannot dispatch provider  
new model remains disabled after discovery  
bad pricing parse cannot overwrite current rate  
full provider list failure cannot mass-disable models  
Admin cost sync is idempotent  
current price update changes future calculation only  
```  
  
**Insufficient tests:**  
  
```text  
"column exists"  
"prompt includes text"  
"function returned 200"  
```  
  
**Use provider fetch mocks for OpenAI endpoints.**  
  
**Never hit billable OpenAI generation during unit tests.**  
  
  
  
**14. Current repo/source references for the agent**  
  
**Verified relevant repository paths at the baseline SHA:**  
  
```text  
supabase/functions/generate-story/_generation_models.ts  
supabase/functions/generate-story/index.ts  
supabase/functions/generate-story/pricing_test.ts  
supabase/functions/_shared/billable-llm.ts  
supabase/functions/_shared/billable-llm_test.ts  
supabase/functions/_shared/direct-billing.ts  
supabase/functions/generation-models/index.ts  
supabase/functions/coherence-check/index.ts  
supabase/functions/coherence-check/_handler.ts  
supabase/functions/run-outline/index.ts  
CathedralOSApp/Services/GenerationModelService.swift  
supabase/migrations/20260514191000_add_generation_models_catalog.sql  
supabase/migrations/20260729180000_add_generation_telemetry.sql  
supabase/migrations/20260729190000_telemetry_weekly_snapshots.sql  
supabase/migrations/20260803194600_pricing_policy_2x_pass_through.sql  
supabase/migrations/20260808153000_add_gpt56_models.sql  
supabase/migrations/20260902203000_add_embedding_model_pricing.sql  
supabase/queries/generation_telemetry_weekly.sql  
docs/generation-budget.md  
```  
  
**Current main source URL root:**  
  
```text  
https://github.com/kje7713-dev/CathedralOS/tree/714767e60e15e8a6a42705a4397de020236777ac  
```  
  
**Official OpenAI references to verify at implementation:**  
  
```text  
https://developers.openai.com/api/docs/models  
https://developers.openai.com/api/docs/models/compare  
https://developers.openai.com/api/reference/python/resources/admin/subresources/organization/subresources/usage/methods/completions  
https://developers.openai.com/api/reference/python/resources/admin/subresources/organization/subresources/usage  
```  
  
  
  
**15. Final agent instruction**  
  
**Implement this as a staged safety/billing bundle, not as a model-system rewrite.**  
  
**The order is intentional:**  
  
```text  
1. make current billing fail closed  
2. discover models  
3. observe/promote official pricing safely  
4. ingest provider actual costs/usage  
5. remove the old duplicate pricing authority  
```  
  
**Do not skip directly to automation while the current null-price path remains fail-open.**  
  
**Do not let a new OpenAI model become customer-visible merely because OpenAI released it.**  
  
**Do not let a missing price become zero.**  
  
**Do not let a failed documentation parser overwrite a known-good production rate.**  
  
**Do not let reconciliation mutate customer history.**  
  
**Do not merge, deploy Supabase, or trigger TestFlight unless explicitly instructed.**  
  
## Stop after each PR and return it for review.  
