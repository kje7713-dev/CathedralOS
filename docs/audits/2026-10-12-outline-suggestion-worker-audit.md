# StoryDonkey outline-suggestion worker audit — 2026-10-12

## Scope and safety

This is a read-only audit of the Tartaria Magna Supabase project (`vrzlwukuslpnqebaakxy`). No production row was reset, deleted, cancelled, retried, or otherwise modified.

## Affected runs (read-only query at 2026-10-12 09:25 EDT)

| run | status | run attempts | provider attempts | settled attempts / credits | model | next reclaim under new policy |
|---|---|---:|---:|---:|---|---|
| `5a6aa27c-9527-43d7-9895-903349e336cf` | `running` | 4 | 5 | 0 / 0 | `gpt-6.1-sol` | terminal: attempt ceiling (next = 5) |
| `336621e0-6dd0-46bb-97a3-8032fd392f3a` | `running` | 5 | 6 | 0 / 0 | `gpt-6.1-sol` | terminal: attempt ceiling and lifetime |
| `63fdfb19-f238-404a-aa2f-68d935d495c0` | `running` | 1 | 2 | 0 / 0 | `gpt-6.1-sol` | terminal: elapsed lifetime |

All three have no completed suggestions, no settled customer charge, and provider errors only of `worker_interrupted`. Their diagnostics show no meaningful planning progress beyond starting/resume-checkpoint dispatches. The run table's `credit_cost_charged` is `0` for all three, but the new terminal message still reconciles provider-attempt rows before saying that no settled charge is recorded.

## Root cause and corrected bounds

The affected runs repeatedly entered `story-material-enrichment` with `gpt-6.1-sol`. The deployed worker used a 150-second OpenAI provider deadline inside Supabase Edge Runtime `waitUntil`; Edge wall-clock termination could occur before the provider timeout or terminal DB update. Expired leases were reclaimed without a maximum attempt count, allowing an endless cycle. On iOS, reconnect polling refreshed the stale timestamp every three seconds, preventing stale-lock recovery and previously clearing the local identity when the retry budget ended.

The focused correction now:

- Keeps the provider deadline at 90 seconds, including response-body consumption and JSON parsing, leaving time for durable reconciliation.
- Limits expired-worker reclaim to five attempts.
- Limits total run lifetime to 30 minutes and meaningful-progress silence to 10 minutes. Checkpoint continuation is not counted as failure; it refreshes the meaningful-progress marker.
- Uses compare-and-set ownership/lease transitions and marks interrupted provider attempts before terminal reconciliation.
- Reconciles `generation_provider_attempts` before constructing an exhausted-run message. Settled stages are preserved; unresolved reconciliation is reported as unresolved, never as zero charge.
- Preserves iOS run ID, selected model, idempotency key, generation identity, and lineage metadata as `connection_unavailable`; connectivity loss is not a server failure and cannot authorize a new billable generation.

## Recovery procedure after deployment

1. Deploy the focused worker fix and wait for the function version to be confirmed.
2. Read each run first; do not assume an expired lease is safe to reclaim without the compare-and-set update.
3. Use the authenticated GET recovery path for each affected run.
4. The first and second runs will reach terminal failure on the next successful reclaim because their attempt ceilings are already reached. The third will reach terminal failure because its elapsed lifetime exceeds 30 minutes. No provider retry or billing mutation should be manually performed.
5. Verify each terminal response includes the reconciled charge classification and no duplicate usage event or ledger entry was created.
6. A new user-approved request may then be started through the normal UI, using a new generation identity.

No recovery operation was executed by this audit.

## Model completion evidence

The production evidence proves interruption and absence of successful enrichment completion, not that `gpt-6.1-sol` cannot satisfy the contract. No live-provider test was run from this environment because credentials and production mutation are prohibited. A safe nonproduction integration run using the selected model, with provider latency, response tokens, finish reason, structured-output validity, and Edge wall-clock duration captured, remains a release blocker for claiming reliable Sol completion.
