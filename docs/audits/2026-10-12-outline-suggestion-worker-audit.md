# StoryDonkey outline-suggestion worker audit — 2026-10-12

## Scope and safety

This is a read-only audit of the Tartaria Magna Supabase project (`vrzlwukuslpnqebaakxy`). No production row was reset, deleted, cancelled, retried, or otherwise modified.

## Affected runs

| run | status | attempts | latest stage | latest lease |
|---|---|---:|---|---|
| `5a6aa27c-9527-43d7-9895-903349e336cf` | `running` | 4 | `starting` | expired 2026-10-11 12:51:39Z |
| `336621e0-6dd0-46bb-97a3-8032fd392f3a` | `running` | 5 | `starting` | expired 2026-10-12 12:46:53Z |
| `63fdfb19-f238-404a-aa2f-68d935d495c0` | `running` | 1 | `starting` | expired 2026-10-12 13:09:31Z |

All three have no `completed_at`, no terminal `error_code`, and no accepted suggestions. Their persisted worker diagnostics point to resuming a planning checkpoint even though the provider attempt was interrupted.

## Provider evidence

The provider-attempt audit found `story-material-enrichment` attempts using `gpt-6.1-sol`. The affected runs contain 4, 5, and 1 completed attempts respectively, each with `status=provider_failed` and `provider_error_code=worker_interrupted`; each run also has a newer `started` attempt with no completion timestamp. No successful provider completion was recorded for enrichment.

The deployed worker used a 150-second OpenAI provider timeout while running inside Supabase Edge Runtime. The worker lease was three minutes, and the provider call was launched from `EdgeRuntime.waitUntil`. A wall-clock shutdown can therefore terminate the invocation before the provider timeout or terminal-state update runs. The durable row remains `running` until a later GET happens to reclaim it; the previous reclaim path had no maximum attempt count, allowing an endless cycle.

## Recovery plan after deployment

1. Deploy the focused worker fix and wait for the function version to be confirmed.
2. Read each run first; do not assume an expired lease is safe to reclaim without the compare-and-set update.
3. For an affected run, use the existing authenticated GET recovery path. The worker will resume from its persisted checkpoint and preserve the existing idempotency key and billing-attempt ledger.
4. Verify one of: `completed` with suggestions, or `failed` with an explicit terminal error and no duplicate charge.
5. If a run reaches the finite-attempt terminal state, create a new user-approved retry through the normal UI rather than mutating the old run.

No recovery operation was executed by this audit.
