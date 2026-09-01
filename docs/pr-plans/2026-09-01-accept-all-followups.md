# Accept All / Run All Follow-ups

**Origin:** PR #489 (`ec014ea`, merged as `6b49f49`)
**Date:** 2026-09-01
**Status:** Backlog after shared embedding deployment

## 1. Add stale Accept All run recovery

- Add a lease/heartbeat and an expiry policy for `outline_embedding_runs`.
- Reclaim runs whose worker stopped after partial progress.
- Preserve completed section IDs and retry only pending/failed sections.
- Keep terminal failure details and snapshot reconciliation idempotent.
- Add focused tests for lease expiry, reclaim, duplicate workers, and restart recovery.

## 2. Make RAG lifecycle reconciliation stable

- Define stable identity and supersession rules for plot threads, open loops, and continuity facts.
- Reconcile repeated Accept All/retry attempts without duplicating semantic rows.
- Preserve provenance and distinguish active, resolved, and superseded state.
- Add regression tests for retries, partial batches, and changed extraction output.

## 3. Replace source-contract tests with service seam tests

- Introduce a small dependency-injected seam around the typed embedding service.
- Test successful direct invocation and typed provider/database failures without reading source files.
- Keep the no-nested-HTTP assertion as an integration/architecture check if useful.

## 4. Device smoke test after deployment

- Install the new TestFlight build.
- Run Accept All on a clean suggestion batch; verify progress, partial failure detail, embeddings, output links, and snapshot persistence after leave/reopen.
- Run Generate 45 Sections / From Here; verify queued/running/retry/completion states, Outputs navigation, and credit settlement.
