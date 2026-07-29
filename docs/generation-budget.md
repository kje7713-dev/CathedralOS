# Generation Budget & Free Tier

> **Status:** Draft v1 · Phase 1 (telemetry) pending · Owner: Kevin · Co-author: OpenClaw
> **Created:** 2026-07-29

This document is the source of truth for CathedralOS's generation pricing and free-tier mechanics. When the implementation drifts from this doc, the doc wins until both sides catch up.

---

## 1. Context

Today the user picks a **length** (Short / Complete / Extended / Chapter) and CathedralOS hands back a generation that may or may not finish. The picker decides pre-commit credits; the model decides the actual scene length. Three problems:

- The user doesn't know what they're paying for in dollars, only in abstract credits.
- Some generations truncate mid-scene (the red "hit model length limit" warning).
- The implicit credit→USD mapping varies wildly across model tiers, so margin is invisible.

This reframe moves the user from picking **shape** to picking **spend**, and gives the server the room to finish what it started.

---

## 2. Goals

1. **Deliver** — the user always gets a complete scene, never a cliff-hanger.
2. **Compensated** — CathedralOS makes money per generation in a margin-aware way that survives growth.
3. **Transparent** — the user sees the spend scale before and during the run, not after.

---

## 3. Product Surface (v1)

### 3.1 Tier matrix

| Tier            | Cost to user  | Credits  | Typical output      | Model                  | Watermark | Use case                       |
|-----------------|---------------|----------|---------------------|------------------------|-----------|--------------------------------|
| Free Preview    | $0            | —        | ~200 tok × 3/proj  | Cheap only             | Yes       | First-time in a new project    |
| Free Tier       | $0            | 5/month  | 200 – 1,500 tok     | Cheap default, premium +surcharge | No | Habitual return |
| Pay-as-you-go   | $0.10 – $3.00 | 2 – 60   | 200 – 5,000 tok     | Auto per budget        | No        | Intentional creation           |
| IAP packs       | $0.99 – $39.99| 20 – 1,200 | Per generation    | Any                    | No        | Top-up / heavy use             |

### 3.2 Free Preview

- **3 generations per project.** Counter resets per project, not globally — encourages exploration across many projects without burning the budget on one.
- **Each generation capped at ~200 output tokens.** Small, tight, useful as a taste.
- **Cheap model only.** The only way to bound our cost on the free path.
- **Watermarked footer:** a single line rendered at the bottom of the output card:
  > *Generated with CathedralOS — tap to upgrade.*
- **Auto-dismisses** once the user has any positive paid-credit balance on their account. The watermark is for the trial, not for life.

### 3.3 Free Tier

- **5 credits per calendar month**, every active user.
- Resets on the 1st of each month (user-local calendar).
- **Daily throttle: max 3 generations per day** regardless of monthly balance. This is the cost-control and fair-use layer — monthly allowance can otherwise blow out on a single power-day.
- **Cheap model default.** Premium model carries a **+50% credit surcharge** (e.g., a 10-credit scene becomes 15 credits on premium). Surcharge is rounded up to whole credits.
- **No watermark.** This is a relationship, not a trial.
- **No accumulation carryover.** Unused monthly credits expire at month-end. Simpler accounting and avoids "use it or lose it" complaint cycles.

### 3.4 Pay-as-you-go (Budget × Model Picker)

- **Budget presets:** **$0.10 · $0.30 · $1.00 · $3.00** (= 2 / 6 / 20 / 60 credits at $0.05/credit).
- **Model picker is user-facing, and the actual model name is shown to the user.** The picker lists every enabled model with its display name visible — e.g., "Cheap — GPT-4o mini," "Standard — Claude 3.5 Sonnet," "Premium — Claude 3 Opus." Tier grouping is organizational; the model name is the unit of choice. Some users care which model they're getting (provider politics, model-specific quirks, vibes), and the UI respects that. The server respects the choice — no server-side override.
- **Effective credits = budget credits × model multiplier.** The picker displays the final credit cost before the user commits, so the price never surprises.
  | Model tier | Multiplier on budget credits |
  |---|---|
  | Cheap  | ×1.0 |
  | Standard | ×1.5 |
  | Premium | ×2.5 |
  New providers (Kimi, MiniMax, etc.) plug in as additional Cheap-tier models with their own multiplier.
- **Minimum charge** is the highest of: model `minimum_charge_credits`, computed `budget × multiplier`, or the floor set in §3.3 for free-tier usage.
- **Pre-flight input token estimation** — `max_output = budget_tokens − estimated_input − safety` (using `estimateTokensFromText` from `_generation_models.ts`, +25% safety).
- **Auto-continue on `finishReason === "length"`** — server chains a "wrap up cleanly" continuation call and stitches the output. Continuation consumes the remaining budget. Stop only when budget is exhausted or the scene closes naturally.
- **Refund unused budget on natural finish** — see §4.
- **Roadmap:** when Kevin adds new cheap providers (Kimi, MiniMax, etc.), they appear as additional Cheap-tier rows with their model name visible — e.g., "Cheap — Kimi," "Cheap — MiniMax." The tier abstraction handles routing and pricing consistently; the model name lets users who care pick the one they want. Existing Cheap-tier users can switch to a new provider with one tap if they prefer it.

### 3.5 IAP Packs (StoreKit)

| Pack price | Credits | $/credit (effective) | Note                       |
|------------|---------|----------------------|----------------------------|
| $0.99      | 20      | ~$0.050              | Entry / impulse             |
| $4.99      | 120     | ~$0.042              | Rational mid                |
| $14.99     | 400     | ~$0.037              | Serious writer              |
| $39.99     | 1,200   | ~$0.033              | Studio / best value         |

iOS carries Apple's standard 30% cut. Effective margins tighten as pack size grows — acceptable because retention value compounds while one-shot margin doesn't.

---

## 4. Refund Policy

| Scenario                                      | Result                                  |
|-----------------------------------------------|-----------------------------------------|
| Scene finishes naturally, budget not exhausted | **Refund unused credits** to wallet     |
| Scene finishes via auto-continue, budget exhausted | No refund                              |
| Scene finishes via auto-continue, scene closes naturally mid-continuation | Refund remainder |
| User cancels mid-run                          | Charge for tokens actually emitted, refund the rest |

- Refunds show in a "Credit history" panel in-app (debit/credit lines per generation).
- Refunded credits are indistinguishable from purchased credits on the wallet.

---

## 5. Telemetry (Phase 1 — first PR)

We already log per generation: `tokens` (input/output/total), `selectedModelId`, `outputBudget`, `durationMs`, `errorCode`, `creditCostCharged`. What's missing is the **model → $/token rate** that converts those into margin.

### 5.1 Schema additions

1. **`model_rates`** table:
   - `model_id` (PK, FK → `generation_models.id`)
   - `input_per_1k_usd` (numeric)
   - `output_per_1k_usd` (numeric)
   - `premium_markup_pct` (numeric, e.g., 0.50 for +50%)
   - `tier` (text: 'cheap' | 'standard' | 'premium')
   - `is_active` (boolean)
   - `updated_at`

2. **New columns on `GenerationUsageEvent`:**
   - `model_input_usd`, `model_output_usd`, `total_model_usd`
   - `credit_revenue_usd` (= `credit_cost_charged × $0.05`)
   - `margin_usd` (= `credit_revenue_usd − total_model_usd`)
   - `margin_pct` (= `margin_usd / credit_revenue_usd`)

3. **Compute on insert** in `supabase/functions/generate-story/index.ts`, using a `model_rates` lookup keyed off `selectedModelId`.

### 5.2 Seeded model rates (best estimates, validate against invoices)

These are **public list prices as of early 2026** — accurate to within ~10%, but **validate against actual provider invoices before Phase 1 ships**. Sources: each provider's published pricing page as of Jan 2026.

| `model_id`             | Tier     | Input / 1k USD | Output / 1k USD | Notes                              |
|------------------------|----------|----------------|-----------------|------------------------------------|
| `gpt-4o-mini`          | cheap    | 0.00015        | 0.0006          | Default per `_generation_models.ts` |
| `gpt-4.1-mini`         | cheap    | 0.0004         | 0.0016          | OpenAI mid-cheap                   |
| `gpt-4.1-nano`         | cheap    | 0.0001         | 0.0004          | OpenAI nano, very cheap            |
| `claude-3-5-haiku`     | cheap    | 0.0008         | 0.004           | Anthropic cheap                    |
| `gemini-2.0-flash`     | cheap    | 0.0001         | 0.0004          | Google cheap                       |
| `gemini-1.5-flash`     | cheap    | 0.000075       | 0.0003          | Google older cheap                 |
| `kimi`                 | cheap    | 0.00015        | 0.0006          | Moonshot Kimi (planned)            |
| `minimax`              | cheap    | 0.00010        | 0.0004          | MiniMax (planned, est.)            |
| `gpt-4o`               | standard | 0.0025         | 0.010           | OpenAI standard                    |
| `gpt-4.1`              | standard | 0.0020         | 0.008           | OpenAI 4.1                         |
| `claude-3-5-sonnet`    | standard | 0.0030         | 0.015           | Anthropic standard                 |
| `gemini-1.5-pro`       | standard | 0.00125        | 0.005           | Google standard                    |
| `claude-3-opus`        | premium  | 0.015          | 0.075           | Anthropic premium                  |
| `gpt-4.1` + reasoning  | premium  | 0.015          | 0.060           | o1 / o3-mini tier                  |
| `o1`                   | premium  | 0.015          | 0.060           | OpenAI reasoning                   |
| `o3-mini`              | premium  | 0.0011         | 0.0044          | OpenAI reasoning small             |

**Validation checklist before Phase 1 ships:**
- [ ] Pull last 30 days of provider invoices, compute actual `input_per_1k_usd` and `output_per_1k_usd` per model. Compare to seeds.
- [ ] Confirm `kimi` and `minimax` rate cards are accurate once endpoints are live (Kevin's note).
- [ ] Mark any provider that introduced pricing changes (rare but possible — Google has done it twice in 2024–25).
- [ ] `is_active = false` for any model you no longer want exposed but want to keep rate data for analysis.

**Margin sanity check at seed values:**
- $0.30 × `gpt-4o-mini` (~600 output tokens): model cost ~$0.0004, revenue $0.30, **margin ≈ 99.9%**. Generous.
- $1.00 × `gpt-4o` (~1500 output tokens): model cost ~$0.015, revenue $1.00, **margin ≈ 98.5%**. Still generous.
- $3.00 × `claude-3-opus` (~5000 output tokens): model cost ~$0.375, revenue $3.00, **margin ≈ 87.5%**. This is where margin tightens noticeably — `premium_markup_pct` should be tuned for this band.
- $3.00 × `o1` (5000 output tokens): model cost ~$0.30, revenue $3.00, **margin ≈ 90%**.

If real invoices show model costs materially higher than these seeds, the budget preset dollar values are the lever — not the multipliers.

### 5.2 Weekly aggregation

A scheduled SQL query (cron) that returns, per week:

- Truncation rate by `(lengthMode × model)`
- Average margin per tier (preview / free / paid)
- Free-tier utilization rate (credits burned vs. allowance)
- Auto-continue rate per budget tier

Output drives every subsequent pricing or tier decision.

---

## 6. Phased Rollout

| Phase | What                                                                 | Status      |
|-------|----------------------------------------------------------------------|-------------|
| 1     | Telemetry table + model rates + margin columns                      | **Next**    |
| 2     | User-picks-model budget picker (alongside length picker for old users) | After 1     |
| 3     | Auto-continue on `finishReason === "length"`                          | After 2     |
| 4     | Free preview + free tier + daily throttle                             | After 3     |
| 5     | Refund-as-credit on natural finish + credit history panel            | After 4     |
| 6     | Live streaming meter + cancel-and-refund                              | After 5     |
| 7     | StoreKit IAP packs live                                               | After 5     |
| 8     | Two-pass draft + polish for budgets ≥ $1                              | After 7     |

Phases 1–4 are the must-ship set. 5–7 make the system feel good. 8 is the premium story.

---

## 7. Open Questions / Future

- **Subscription tier** — monthly credit allowance + premium model access. Decide once Phase 7 ships.
- **Per-prompt-pack budget profile** — recipes remember typical spend ("this one usually costs 4 credits"). One-tap regen within the envelope.
- **Async generation + push notification** — submit, close app, ping when ready. Removes the "watch the meter" UX pressure.
- **Collaborative mid-stream redirection** — user can prompt mid-generation to redirect ("actually make it rain"). Treated as a continuation with its own micro-budget.
- **iOS vs Android price parity** — Google Play takes 15% on first $1M, 30% after. Pack ladder may need adjustment per platform.
- **Free tier + paid credits co-existence** — which bucket gets debited first? Recommend: paid first (so free allowance feels like a bonus, not a default).

---

## 8. Glossary

- **Budget** — the credit amount the user commits to a single generation.
- **Generation** — one or more chained LLM calls producing a single output.
- **Auto-continue** — server behavior: when `finishReason === "length"` and budget remains, call again with a "wrap up cleanly" prompt and stitch.
- **Free Preview** — per-project, watermarked, cheap-model trial generation.
- **Free Tier** — monthly credits at no cost, no watermark, with daily throttle.
- **Daily throttle** — fair-use cap (3 generations/day) layered on top of monthly free allowance.
- **Refund** — unused budget credits returned to user wallet after generation.
- **Premium surcharge** — +50% credit cost when a free-tier user opts into a premium model.

---

## 9. References

- `docs/architecture.md` — data model and generation flow.
- `docs/generation-credits.md` — current credit accounting.
- `docs/generate-story-edge-function.md` — edge function behavior.
- `docs/backend-credit-enforcement.md` — server-side credit math.
- `docs/storekit-entitlements.md` — IAP wiring.
