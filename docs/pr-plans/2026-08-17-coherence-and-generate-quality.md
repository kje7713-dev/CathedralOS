# PR Plan 2026-08-17 — Coherence check failures + generate-prompt drift

Status: **DRAFT, pending Kevin review. Do not implement until approved.**

Owner: Kevin (review), agent (implementation).
Branch convention: `fix/coherence-and-generate-quality-{X|Y|Z}` (separate PRs).
Target ship order: **X → Y → Z** (X fixes the immediate kickoff-sheet complaint; Y catches the rest; Z locks down the LLM at the prompt level).

---

## Context (repro from 2026-08-17 21:03 EDT)

User had a project with:
- **Section 1 "Smoke Test"** — status `Accepted`, summary `"Ted is cornered by a trivial chain of random humiliations—bad luck, a mo..."`, beat `"Test"`
- **Section 2 "Smoke Test (copy)"** — status `Draft`, summary `"Ted and Fred and Betty are dead now"`, container `Scene`, POV `First person`

On kickoff, the coherence-check **did not fire** any warning despite clear character-state contradiction (`"Ted and Fred and Betty are dead now"` vs `Ted is cornered by humiliations, beat=Test, embed-section extracted with character_deltas likely showing Ted alive`).

After kickoff, `generate-story` produced an output with FOUR problems:

1. **POV drift mid-section** — started 1st-person (`"My heart pounded"`), drifted to third-person omniscient (`"Betty leaped forward, grabbing my wrist"`).
2. **Premise inversion** — user premise says characters are dead; output writes them alive and fighting in a garage. ~3000 words of meaningless prose.
3. **"Test" leak** — output `"Test," he muttered` — the model took the word `Test` from the section title `"Smoke Test (copy)"` and used it as character dialogue.
4. **Length overrun** — output ≈3000 tokens for a `Scene` container that budgets 800–1800 (the model hit the largest of three competing token signals).

Plus invented a 4th character (`Steve`) not present in any prior canon, character list, or prompt pack selection.

---

## PR-360-X — pre-gen coherence check: explicit-claim handling + positive-inference rule

**Goal:** make the kickoff-sheet coherence check fire reliably on "characters are dead in proposed section while alive in prior canon", even when the structured memory only implies aliveness (no explicit `alive=true` field).

**Symptom it fixes:** Smoke Test repro (pre-gen check returns `[]` despite the obvious character-state contradiction).

**Scope:** backend only. No iOS changes.

**Files:**
- `supabase/functions/coherence-check/index.ts` (single file, ~+80/-10)
- `supabase/functions/coherence-check/index_test.ts` (extend existing) — exercise the Smoke Test repro inline

**Code-level changes:**

1. **Positive-inference aliveness rule.** In the per-neighbor text builder, after rendering `character_deltas` and `scene_ending_state`, append an explicit `ALIVE-DEFAULTS:` line derived from the structured fields:
   ```
   ALIVE (default — no death/injury signal in structured memory):
     - Ted
     - Fred
   DEAD/INJURED (only if structured memory says so):
     - (none)
   ```
   Rule: any character appearing in `character_deltas[].character_name` (regardless of `injuries` field value), or any character listed in `scene_ending_state.character_positions[].character`, with no explicit `injuries`/`status='deceased'`/`status='dying'`, is treated as ALIVE for purposes of contradiction checks. The rule is documented in the system prompt as: *"absence of death signal = presumed alive; do not require an explicit `alive=true` field".*

2. **Explicit-claim extraction on the proposed side.** Before calling OpenAI, run a deterministic (no-LLM) regex pass over `body.section.title + " " + body.section.summary`:
   ```
   /(is |are )?(dead|dies|died|kill(ed|s)?|deceased|gone|missing|absent)\b/i
   /(wiped? out|massacred|executed|assassinated|murdered)/i
   ```
   If matches found, extract character names from the surrounding ±60 chars. Build an `explicitClaims: [{ character_name, claim_kind: "dead"|"missing"|"killed", source_text }]` list and inject it into the user prompt as a labelled block above the LLM call:
   ```
   EXPLICIT DEATH/MISSING CLAIMS DETECTED IN PROPOSED SECTION:
     - "Ted": source="Ted and Fred and Betty are dead now" (claim kind: dead)
     - "Fred": (same)
     - "Betty": (same)
   ```
   The LLM then MUST compare these claims against the `ALIVE/DEAD/INJURED` lists in the accepted sections and emit a `character_state` warning for any character listed in `ALIVE` (or present in neighbor canon without explicit death signal).

3. **Drop "be sparing" guardrail on explicit claims.** In the system prompt, replace the closing line:
   ```
   "If there are no real contradictions, return {"warnings": []}. Be sparing and accurate — every warning you emit will be shown to the writer as a soft-warn before they commit credits to a generation run, so false positives are costly."
   ```
   with:
   ```
   "If there are no real contradictions, return {"warnings": []}.
   
   Special rule for EXPLICIT claims in the proposed section:
   - If the proposed section explicitly claims a character is dead, killed, missing, or absent, AND that character appears in the ALIVE list (or is mentioned as alive) in any accepted section, emit a `character_state` warning with `severity: 'high'` citing the contradicting section. This is a HIGH-confidence flag and should NEVER be silently dropped.
   - If the proposed section explicitly claims an alive state for a character who is marked DEAD/INJURED in a prior scene, that is also a HIGH-confidence flag.
   - For weak/implicit signals (theme echoes, stylistic proximity, speculative concerns), still be sparing — only flag what you can cite to a specific accepted section."
   ```
   This narrows the "be sparing" rule to its correct domain (weak signals) and explicitly carves out an EXPLICIT-CLAIM case where the check must fire.

4. **Deterministic fallback against LLM underreporting.** After the OpenAI call, do a post-LLM check — for every character in `explicitClaims` that is also in any neighbor's `ALIVE` list (or mentioned in any neighbor's structured memory without a death signal), emit a `CoherenceWarning` with `reason: "<Character> was alive in section <X> but the proposed section claims they are <claim_kind>"`, `severity: "warn"`. This is a deterministic guard against LLM underreporting. Even if the LLM returns `[]`, the deterministic fallback surfaces the contradiction.

5. **Test the Smoke Test repro inline.** Extend `index_test.ts`:
   - Construct a neighbor row from "Smoke Test" with character_deltas for Ted (alive, injuries=none, location=cornered-by-humiliations) and scene_ending_state with Ted in alive positions.
   - Construct a proposed section with summary "Ted and Fred and Betty are dead now".
   - Run the edge function logic and assert: at least one `CoherenceWarning` is returned, with `reason` mentioning Ted's aliveness contradicting the death claim.

**M/d/T:**
- iOS Build (single backend-only change; iOS Build runs but should pass unchanged)
- Supabase Deploy (must be triggered manually — workflow is `workflow_dispatch`; see PR #362)
- Smoke test on TestFlight (Kevin re-runs the kickoff on the Smoke Test project; expect to see yellow warning)

**Dependencies:**
- None — PR #362 (workflow sync) already shipped, so this will actually deploy.

**Estimated size:** ~80 lines net. One file + test extension.

---

## PR-360-Y — post-generation coherence pass inside generate-story

**Goal:** catch POV drift, premise inversion, and other output-vs-premise contradictions that the pre-gen check can't see. This is the missing half of Kevin's complaint ("switches pov and says the characters are already dead").

**Scope:** backend only. iOS already has `coherenceWarningsRow` for pre-gen warnings; for post-gen, we'll surface the warnings inside a new `generation_output_warnings` table joined to `generation_outputs`. iOS UI updates can be a follow-up if the data lands first.

**Files:**
- `supabase/functions/generate-story/index.ts` — after the LLM call and before persisting the output, fire a post-generation coherence pass
- `supabase/functions/coherence-check/index.ts` — extend the request shape to support a `mode: "pre-generation" | "post-generation"` parameter; in `post-generation` mode, the function expects the LLM's actual `output_text` and reuses the same premise + neighbor comparison but ALSO checks POV drift, invented characters, and premise-vs-output consistency
- `supabase/migrations/<date>_post_gen_warnings.sql` — new `generation_output_warnings` table: `(id, generation_output_id, warning_type, severity, message, conflicting_section_ids[], created_at)`. Indexed on `generation_output_id`. RLS mirrors `generation_outputs` (row-level read for owner only).

**Code-level changes:**

1. **Extend coherence-check request shape.** Add optional `mode: "post-generation" | "pre-generation"` (default `pre-generation`) and optional `output_text: string`. When `mode === "post-generation"`, render the output text into the prompt alongside the proposed section and add an `output-vs-premise consistency` check category.

2. **New prompt category.** Add to the system prompt:
   ```
   6. Output-vs-premise consistency (post-generation mode only): if the LLM's actual output:
      - Drifts POV mid-section (e.g., starts 1st-person, ends 3rd-person without justification)
      - Invents characters not present in the proposal or any prior section
      - Contradicts explicit claims in the proposal (e.g., proposal said "X is dead", output writes X alive)
      - Uses character names that don't appear in the proposed or accepted canon
      ...emit a warning with severity "high" or "warn".
   ```

3. **generate-story flow change.** After the LLM returns `output_text`, make a fire-and-forget (or await, configurable) call to `coherence-check` with `mode: "post-generation"` and `output_text`. Persist the returned warnings to the new `generation_output_warnings` table alongside the `generation_outputs` row. Don't block generation on this — if it errors or times out (10s budget), log and continue.

4. **iOS surface (defer to follow-up).** When loading the generation output detail view, query `generation_output_warnings` for the output and show the same yellow card UI used in the pre-gen kickoff sheet.

**M/d/T:**
- iOS Build (passes unchanged — backend only)
- Supabase Deploy
- Smoke test on TestFlight (generate a new section and check that POV drift / invented characters get flagged)

**Dependencies:**
- PR-360-X (so the post-gen check inherits the positive-inference + explicit-claim logic)
- New migration must run with PR

**Estimated size:** ~150 lines net. Three files (edge function, edge function, migration).

---

## PR-360-Z — generate prompt anchoring

**Goal:** stop the LLM from drifting in POV, ignoring the scene premise, leaking the section title as dialogue, and running over the container's token budget. This is "don't generate the broken output in the first place" — defensive at the prompt level.

**Scope:** backend only (single edge function). No iOS changes.

**Files:**
- `supabase/functions/generate-story/index.ts` — refactor `buildPrompt` so premise + POV live in the SYSTEM message; sanitize section titles; switch `maxCompletionTokens` to `container.hardCap` when set
- `supabase/functions/generate-story/_prompt_test.ts` (new) — exercise the title-sanitization helper

**Code-level changes:**

1. **Move section premise into SYSTEM message.** Render at the top of `craftLines`:
   ```
   ## Scene Premise (INVIOLABLE — DO NOT REWRITE OR INVERT)
   Title: <sanitized title>
   Summary: <summary>
   
   The summary above describes the END STATE of this scene. If it says a character is dead, the scene is set AFTER their death (e.g., memorial, investigation, afterlife). DO NOT write the character as alive in this scene.
   ```
   Then keep the existing `## Notes` block as additional context.

2. **Move POV to SYSTEM message.** Currently POV instruction lives in the user message's `## Writing Task`. Move it into the SYSTEM message next to the container instructions (`Write in first person (I, me, my). The viewpoint character narrates in their own voice.`). Update comment to reflect why.

3. **Sanitize section titles before sending to LLM.** New helper `sanitizeTitleForLLM(title: string): string`:
   ```ts
   // Strip draft suffixes that the model might recycle as dialogue.
   // "(copy)", "(test)", "(draft)" → empty
   // Surrounding punctuation: keep — "Smoke Test (copy)" → "Smoke Test"
   // Trim trailing/leading whitespace
   ```
   Run this on `body.section.title` before injecting it into the prompt.

4. **Switch `maxCompletionTokens` to `container.hardCap` when set.** Currently:
   ```ts
   const maxCompletionTokens = Math.min(
     outputBudget,
     selectedModel.max_output_tokens ?? outputBudget,
   );
   ```
   Change to:
   ```ts
   const containerHardCap = containerConfig[req.container]?.hardCap;
   const maxCompletionTokens = Math.min(
     outputBudget,
     selectedModel.max_output_tokens ?? outputBudget,
     containerHardCap ?? outputBudget, // container hardCap wins when present
   );
   ```
   Triple-budget → single budget. The model's expected range is in the container config; the hard cap is the API max.

5. **Add an explicit post-write self-check in the SYSTEM message.** Before the "## Writing Instructions" block, add:
   ```
   ## Pre-Return Self-Check (CRITICAL)
   Before you return your response, verify:
   - POV: the entire output is in the requested POV (no drift 1st-person → 3rd-person).
   - Characters: every named character comes from the proposal or an accepted prior section. Names not in canon (e.g., "Steve" if no Steve exists) are PROHIBITED unless the user explicitly introduces them via the proposal.
   - Premise: the scene is consistent with the scene premise above. If the premise says "X is dead", X does NOT appear alive in the scene.
   - Length: end within the container's expected range; do not pad or sprawl past it.
   ```

6. **Drop the `narrative shape: Confrontation` forced default.** The current `inferredShape` is hardcoded to `"Confrontation"` for every generation — that's why every output reads like a fight scene. Replace with: `const inferredShape = "Driven by the scene premise and character state"` (or infer from the section's summary signal).

**M/d/T:**
- iOS Build (passes unchanged — backend only)
- Supabase Deploy
- Smoke test: regenerate the Smoke Test (copy) section. Expect output to: start and stay in 1st-person, NOT contain "Steve", NOT have characters alive if premise said dead, be in 800–1800 token range.

**Dependencies:**
- None — can ship in parallel with PR-360-X.

**Estimated size:** ~120 lines net. One file + a small test file.

---

## Order of operations + dependencies

1. **PR-360-X** ships first. Same-day targeted fix for Kevin's immediate complaint.
2. **PR-360-Y** ships second. Addresses the post-generation half (POV drift, premise inversion in output).
3. **PR-360-Z** ships third. Defensive prompt-level lockdown that prevents the next round of issues.

All three can run independently of each other in code review, but Z unblocks X's testing in a useful way (the test for X is a unit test that doesn't need Z merged). Y depends on X (the post-gen check reuses the new positive-inference + explicit-claim logic).

---

## Open questions for Kevin

1. **Acceptance bar.** Are you OK with PR-360-X's deterministic fallback firing a warning even when the LLM would have returned `[]`? This is in tension with "be sparing" — the deterministic rule is conservative in a different way (it fires on every death claim vs. an alive canon character, no LLM judgement needed). My recommendation: yes, fire the deterministic fallback. False positives are tolerable here; missing a clear contradiction is not.

2. **Post-gen UI surfacing.** PR-360-Y stores warnings server-side but defers the iOS UI to a follow-up. Are you OK with the data landing first and the UI shipping as a separate, smaller PR? Or do you want the iOS warning card on the output detail screen in the same PR as the backend?

3. **Generated-status in pre-gen check.** I mentioned earlier that the pre-gen check only queries `status="accepted"` sections. Some users (like the Smoke Test repro) have only "generated" sections, not yet accepted. Should PR-360-X also widen the scope to include `status="generated"` (still excluding `status="draft"`)? My recommendation: yes — sections that have actually run generation have real structured memory and are reasonable canon for the check.

4. **Length-budget unification scope.** PR-360-Z's `container.hardCap` change will surface as shorter outputs in some cases. Are you OK with the outputs being capped at the container's hard limit (which may be lower than the length-mode budget), or do you want length-mode budget to win when it's smaller? My recommendation: container.hardCap wins always — it's the natural stopping point for the form.

5. **"Test" leak only vs. title-sanitization in general.** PR-360-Z sanitizes "(copy)", "(test)", "(draft)" suffixes. Should we go further (sanitize ALL trailing punctuation + length-limit titles to 80 chars)? My recommendation: keep it to the suffixes that have caused actual leaks. Don't add aggressive title truncation yet — it's a separate UX concern.

---

## Memory / state handling

- After all three PRs ship, update `memory/2026-08-17.md` with a "generate-prompt + coherence-check overhaul" section capturing: the four failure modes observed, the three-PR fix, the lessons learned (positive-inference rule, explicit-claim carveout, deterministic fallback, premise anchoring).
- Store kevbot-brain chunks for:
  - "CathedralOS pre-gen coherence-check: positive-inference + explicit-claim deterministic fallback" (workflow, importance 9)
  - "CathedralOS post-gen coherence check inside generate-story" (architecture, importance 8)
  - "CathedralOS generate-story: scene premise anchoring + container.hardCap wins" (project_convention, importance 8)
  - "CathedralOS section-title sanitization for LLM prompts (strip (copy), (test), (draft))" (project_convention, importance 7)
