# Production Deployment Coverage Audit

The latest `main` deployment workflow contains one deploy step for every production Edge Function directory with an `index.ts` entry point. PR 6 adds `scripts/verify-supabase-deploy-coverage.py` and runs it before the Supabase CLI setup/deploy steps, so a newly added function cannot silently remain undeployed.

The guard intentionally ignores `supabase/functions/_shared`, which contains imported modules rather than deployable functions. It does not alter JWT verification modes or rewrite historical migrations.

Validation on the PR branch: `python3 scripts/verify-supabase-deploy-coverage.py` reports all 21 Edge Functions covered, and `git diff --check` passes.
