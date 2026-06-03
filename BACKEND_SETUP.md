# Backend Setup — CathedralOS Supabase Integration

This document explains how to configure the Supabase backend for CathedralOS.
The iOS app uses a thin configuration layer (`SupabaseConfiguration`) to read
Supabase connection details from Info.plist at runtime. No backend secrets are
stored in the app binary.

---

## Required values

| Key | Description |
|-----|-------------|
| `SupabaseProjectURL` | Your Supabase project URL, e.g. `https://abcdef.supabase.co` |
| `SupabaseAnonKey` | Your Supabase **public** anon key (safe to embed in the client) |
| `PublicSharingBaseURL` | Public sharing API base URL, e.g. `https://abcdef.supabase.co/functions/v1/public-sharing` |

---

## What NOT to put in the iOS app

- **Service-role key** — never embed this; it grants full database access
- **OpenAI API key** — held server-side only, behind your Edge Functions
- Any other backend secret

---

## How to configure locally

### Option A — Info.plist entries (simplest for a single scheme)

Add these entries directly to `Info.plist` (or via Xcode build settings using
the `INFOPLIST_KEY_` prefix):

```xml
<key>SupabaseProjectURL</key>
<string>https://YOUR_PROJECT_REF.supabase.co</string>

<key>SupabaseAnonKey</key>
<string>YOUR_ANON_PUBLIC_KEY</string>

<key>PublicSharingBaseURL</key>
<string>https://YOUR_PROJECT_REF.supabase.co/functions/v1/public-sharing</string>
```

### Option B — Per-scheme `.xcconfig` (recommended for dev / staging / prod)

1. Create scheme-specific `.xcconfig` files (e.g. `Config.Debug.xcconfig`,
   `Config.Release.xcconfig`).
2. Add the following variables to each file:

   ```
   SUPABASE_PROJECT_URL = https://YOUR_PROJECT_REF.supabase.co
   SUPABASE_ANON_KEY = YOUR_ANON_PUBLIC_KEY
   PUBLIC_SHARING_BASE_URL = https://YOUR_PROJECT_REF.supabase.co/functions/v1/public-sharing
   ```

3. Reference the variables in `Info.plist`:

   ```xml
   <key>SupabaseProjectURL</key>
   <string>$(SUPABASE_PROJECT_URL)</string>

   <key>SupabaseAnonKey</key>
   <string>$(SUPABASE_ANON_KEY)</string>

   <key>PublicSharingBaseURL</key>
   <string>$(PUBLIC_SHARING_BASE_URL)</string>
   ```

4. Assign each `.xcconfig` file to the corresponding build configuration in
   Xcode → Project → Info → Configurations.

5. **Add the `.xcconfig` files to `.gitignore`** so they are never committed.

---

## How to configure in CI

Set the following secrets in your CI environment (e.g. GitHub Actions secrets):

- `SUPABASE_PROJECT_URL`
- `SUPABASE_ANON_KEY`
- `PUBLIC_SHARING_BASE_URL`

For the admin/dev TestFlight credit-grant flow, also configure this Supabase
Edge Function secret server-side (never in the iOS app):

- `ADMIN_USER_IDS` — comma-separated Supabase user UUIDs allowed to call
  `admin-grant-credits`

Inject them into the build using `-xcconfig` or `INFOPLIST_FILE_KEY` arguments:

```yaml
- name: Build
  run: |
    xcodebuild \
      -scheme CathedralOSApp \
      SUPABASE_PROJECT_URL="${{ secrets.SUPABASE_PROJECT_URL }}" \
      SUPABASE_ANON_KEY="${{ secrets.SUPABASE_ANON_KEY }}" \
      PUBLIC_SHARING_BASE_URL="${{ secrets.PUBLIC_SHARING_BASE_URL }}"
```

---

## What happens if config is missing

If either `SupabaseProjectURL` or `SupabaseAnonKey` is absent:

- `SupabaseConfiguration.isConfigured` returns `false`
- `SupabaseConfiguration.validatedConfiguration()` throws a
  `SupabaseConfigurationError` with a clear message naming the missing key
- The **Account** tab shows a "Backend not configured" warning
- No existing local-only app flows (Projects, Profile, Cathedral editor) are affected

---

## Architecture overview

```
SupabaseConfiguration          ← reads Info.plist, validates keys
         │
         ▼
ValidatedSupabaseConfiguration ← type-safe config struct with URL builder
         │
         ▼
SupabaseBackendClient          ← BackendClient protocol implementation
         │
    ┌────┴────────────────────────────┐
    ▼                                 ▼
AuthService (BackendAuthService)   Future: GenerationBackendService
                                           UsageSyncService
```

All backend calls (generation, sharing, usage sync) flow through this layer.
No local-only flows are broken by its presence.

---

## Authentication: Sign in with Apple

CathedralOS uses Sign in with Apple as the primary iOS authentication method.
The flow is:

1. `BackendAuthService.signInWithApple()` generates a cryptographically secure nonce.
2. `ASAuthorizationController` presents the system sign-in sheet.
3. On success, the Apple identity token is exchanged for a Supabase session via
   `POST /auth/v1/token?grant_type=id_token` (no Supabase Swift SDK required).
4. The Supabase JWT access token, refresh token, user ID, and email are stored in
   the iOS keychain.
5. `AuthState` transitions to `.signedIn(AuthUser)`.

Sign-in is **never** forced on app launch. Local-only operations (create projects,
edit characters/settings, build prompt packs, export JSON/markdown) always work
without a signed-in session.

---

## Cloud feature gating

The following actions require an active signed-in session:

| Action | Gating mechanism |
|--------|-----------------|
| Generate via backend | `SupabaseGenerationService.validateConfigAndAuth()` |
| Sync / restore project snapshots | `ProjectCloudSyncService` signed-in auth check |
| Sync outputs | `SupabaseGenerationOutputSyncService.requireSignedIn()` |
| Publish / unpublish | `BackendPublicSharingService.requireSignedIn()` |
| Report shared content | `BackendPublicSharingService.requireSignedIn()` |
| Record remix events | `BackendRemixEventService` auth check |

When a user is signed out, all of these throw a `.notSignedIn` error and surface
a clear message directing them to the Account tab. No action silently fails.

---

## Security notes

- **Service-role key** — never embed this; it grants full database access.
  The iOS app uses only the anon key.
- **OpenAI API key** — held server-side only, inside Edge Functions.
  Never sent from the client.
- **ADMIN_USER_IDS** — server-side Edge Function secret used to gate the
  developer/TestFlight credit-grant endpoint. Never embed this allowlist in a
  production client build.
- **Anon key** — the public Supabase key. Safe to embed in the app binary.
  Used in the `apikey` header for Edge Function and REST API calls.
- **User JWT** — the Supabase access token issued at sign-in. Stored in the
  iOS keychain. Sent as the `Authorization: Bearer <token>` header for
  user-scoped REST API calls protected by Row-Level Security.
- **Refresh token** — stored in the iOS keychain. Used to renew the access
  token without requiring the user to sign in again.
- **Do not commit** any of the above to version control. Use `.xcconfig` files
  (gitignored) or CI secrets for build-time injection.

### Optional debug/TestFlight UI allowlist

If you want the app to show the Developer Credits section before backend
confirmation returns, you may add an optional `DeveloperAdminUserIDs` Info.plist
entry (comma-separated string or string array). Leave it unset for production
App Store builds.

---

## Cloud-first data lifecycle

As of the `fix/cloud-first-data-recovery` change, CathedralOS enforces a
single cloud-first data policy for signed-in users.

### Policy summary

| Store | Role |
|-------|------|
| **Supabase** (`project_snapshots`, `generation_outputs`) | Durable source of truth for signed-in users |
| **SwiftData** (local SQLite) | Local cache / editing store |
| **Local JSON backups** | Emergency fallback only (third priority) |

Data is never silently lost: if the primary SwiftData store fails, the app
enters **Recovery Mode** using a clean recovery SQLite store and offers
cloud restore.

### Lifecycle events

#### App launch (normal)
1. Open primary SwiftData store.
2. If signed in: pull `project_snapshots` and `generation_outputs`, push dirty/local-only rows, save context.
3. If store fails: copy SQLite artefacts to a timestamped `SwiftDataRecovery` folder, open a clean recovery store, show Recovery tab.

#### App update
1. Before sync: back up all local projects and outputs to JSON.
2. Pull cloud data and push dirty rows.
3. Log before/after counts.

#### Sign-in
1. Refresh session.
2. Pull `project_snapshots` and `generation_outputs`.
3. Merge into local store (cloud wins if `updated_at` is newer; never resurrect tombstoned rows).
4. Push local-only rows.

#### Sign-out
- Local projects, outputs, and JSON backups are **not deleted**.
- Only auth/session state is cleared.

#### App reinstall
- After sign-in, the app detects an empty local store and offers **Restore From Cloud**.

### Deletion policy

Each deletion action shows an explicit choice:

| Action | Effect |
|--------|--------|
| **Delete Local Only** | Deletes SwiftData row, writes `sync_tombstones` row with `deletion_scope = local_only`. Cloud row is preserved. Row will not be re-imported on next pull. |
| **Delete Everywhere** | Unpublishes shared output (if applicable), deletes `generation_outputs` / `project_snapshots` cloud row, writes tombstone with `deletion_scope = everywhere`, deletes SwiftData row. |
| **Cancel** | No changes. |

### Tombstone table

`public.sync_tombstones` prevents deleted rows from being resurrected on
subsequent cloud pulls. The iOS `SyncTombstoneService` fetches tombstones
before each reconcile pass and skips any cloud rows whose `cloud_entity_id`
or `local_entity_id` matches a tombstone.

### Coordinator

`DataDurabilityCoordinator` is the single entry-point for all lifecycle
events. Views call:

```swift
DataDurabilityCoordinator.shared.performAppLaunch(context:isFirstLaunchAfterUpdate:recoveryContext:)
DataDurabilityCoordinator.shared.performSignInSync(context:)
DataDurabilityCoordinator.shared.performSignOut(context:)
DataDurabilityCoordinator.shared.performManualSyncAll(context:)
```

Individual services (`ProjectCloudSyncService`, `SupabaseGenerationOutputSyncService`,
`LocalProjectBackupService`, `LocalGenerationOutputBackupService`) remain
responsible for their own domain logic; the coordinator owns call order and
error aggregation.

### Required Supabase objects

The migration `20260603000000_cloud_first_data_durability.sql` adds:

- Explicit `GRANT` statements for `generation_outputs` and `shared_outputs`.
- Unique partial index `generation_outputs(user_id, local_generation_id) WHERE local_generation_id IS NOT NULL` for safe upsert deduplication.
- `public.sync_tombstones` table with RLS (users can only access their own rows).

All existing RLS policies remain enabled.
