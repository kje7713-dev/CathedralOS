# Outline pipeline regression repair

## Scope

This repair is anchored to the last known working implementation at
`0a591ff25ec7d6246beaeaefc3df4b2b1cd9e7bf` and keeps the model picker and
GPT-6-family reasoning pass-through introduced by PR #711. It does not change
prompts, response schemas, allocation, expansion, billing prices, or model
options.

## Root causes

1. **PR #700 temperature capability regression.** The provider changed from
   forwarding the historical `temperature: 0.7` to excluding every `gpt-5` and
   `gpt-6` model with one broad regex. GPT-5.4 mini is the verified exception,
   including the production model `gpt-5.4-mini-2026-03-17`; Sol, GPT-6 Luna,
   GPT-6 Astra, and GPT-5.6 Luna remain temperature-free.
2. **PR #706 recovery regression.** A worker killed by `WallClockTime` left a
   resumable run with a durable checkpoint. The next delayed GET poll could
   terminalize it as `worker_no_progress` solely because the checkpoint clock
   was older than ten minutes. No-progress is now retained as diagnostics;
   only the absolute 30-minute lifetime can terminalize an otherwise resumable
   run. Expired leases still use compare-and-set reclaim, bounded attempts,
   atomic ownership, and the existing billing-attempt idempotency keys.
3. **Deadline margin regression.** The outline worker used a 150-second
   provider deadline, equal to Supabase's documented Free-plan 150-second
   wall-clock limit. The provider could therefore still be running when the
   platform killed the worker. The repaired outline deadline is 120 seconds,
   leaving 30 seconds for settlement and checkpoint persistence. Supabase
   reference: https://supabase.com/docs/guides/functions/limits
4. **GPT-5.4 mini truncation is separate.** The production mini run returned
   after 93.1 seconds with `finish_reason: length` and malformed JSON. This is
   not fixed by worker recovery. The repaired parser classifies that response
   as `provider_output_exhausted`, preserves the billable-attempt semantics,
   and explicitly reports that a separate output-budget/retry decision is
   required; this PR does not increase budgets or split prompts.

## Execution flow

Before: `POST -> one worker slice -> provider call -> checkpoint/yield` was
followed by a recovery policy that could convert a delayed poll into a terminal
`worker_no_progress` failure even when a checkpoint was intact.

After: `POST -> claim one lease -> resume the persisted stage -> one provider
call -> durable checkpoint -> pending continuation`. A killed slice is
reclaimed only after its lease expires; the next slice rehydrates the stored
stage/material/allocation state. A delayed poll does not erase that recovery
path. A 30-minute lifetime, five-attempt ceiling, lease fencing, and durable
billing idempotency remain in place.

## Compatibility contract

- Model ID and selected `reasoningEffort` remain persisted and passed through.
- `low`, `medium`, and `high` remain valid for GPT-6 Luna, GPT-6.1 Sol, and
  GPT-6 Astra only; unsupported models receive no reasoning field.
- GPT-5.4 mini receives `temperature: 0.7`; unsupported reasoning models do not
  receive custom temperature.
- Prompts, schemas, allocation, validation, expansion, and billing identities
  are unchanged.

## Automated coverage

Focused Deno coverage includes the GPT-5.4 mini dated-model payload,
unsupported temperature/reasoning combinations, the 120-second deadline
margin, checkpoint recovery after delayed polling, and explicit
`finish_reason: length` output-exhaustion classification. No live provider call
is used.
