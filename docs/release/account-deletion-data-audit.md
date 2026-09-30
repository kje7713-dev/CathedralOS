# Account deletion data lifecycle audit

Starting from `main` at `83a9b10d66affba4dc5e794fa268bead1cecf331`.

## Deletion behavior

The authenticated `delete-account` Edge Function derives the user ID from the verified JWT. It does not accept a target user ID from the request body. Before deleting the Supabase Auth user it removes owned EPUB/export rows whose historical foreign keys do not cascade, removes owned Storage artifacts, and then calls `auth.admin.deleteUser(userID)`. The remaining user-owned rows use `auth.users(id) ON DELETE CASCADE`; nullable audit/report references are retained without the deleted identity.

| Entity | Action | Basis |
| --- | --- | --- |
| `profiles` | delete | `auth.users` cascade |
| `project_snapshots`, `generation_outputs`, `story_arcs`, `outlines`, sections, runs, embeddings, tombstones, aliases | delete | user/project foreign-key cascades and ownership model |
| `generation_usage_events`, `user_entitlements`, `user_credit_ledger`, `credit_grants`, `app_store_transactions`, provider attempts | delete | user foreign-key cascades; financial records are account-scoped and not retained under a deleted identity |
| `shared_outputs` and shared EPUB publication rows | delete | publisher-owned content must not remain attributable after account deletion |
| `shared_output_reports` | retain only non-identifying report record; reporter FK is `ON DELETE SET NULL` | preserve moderation audit without retaining deleted reporter identity |
| `remix_events` | delete | user-owned activity; source shared-output reference is nullable |
| `export_metadata`, `export_jobs` | delete explicitly | historical migrations have non-cascading auth references |
| owned `exports`, `covers`, `shared-output-images` objects | delete | paths are collected from owned metadata / shared rows before database deletion |

## Local data

After successful server deletion, the iOS flow deletes local `StoryProject` and `GenerationOutput` rows before signing out. This prevents a newly-created account from re-uploading the deleted account's local drafts through normal sign-in sync.

## Sign in with Apple

Supabase Auth user deletion invalidates the Supabase account/session. Apple authorization revocation is not currently executable by the app because the repository does not persist an Apple refresh token or an operator-configured Apple revoke credential. This remains an external release requirement: configure and verify Apple credential revocation if Apple requires it for the production Sign in with Apple account lifecycle.
