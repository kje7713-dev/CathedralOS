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
```

### Option B — Per-scheme `.xcconfig` (recommended for dev / staging / prod)

1. Create scheme-specific `.xcconfig` files (e.g. `Config.Debug.xcconfig`,
   `Config.Release.xcconfig`).
2. Add the following variables to each file:

   ```
   SUPABASE_PROJECT_URL = https://YOUR_PROJECT_REF.supabase.co
   SUPABASE_ANON_KEY = YOUR_ANON_PUBLIC_KEY
   ```

3. Reference the variables in `Info.plist`:

   ```xml
   <key>SupabaseProjectURL</key>
   <string>$(SUPABASE_PROJECT_URL)</string>

   <key>SupabaseAnonKey</key>
   <string>$(SUPABASE_ANON_KEY)</string>
   ```

4. Assign each `.xcconfig` file to the corresponding build configuration in
   Xcode → Project → Info → Configurations.

5. **Add the `.xcconfig` files to `.gitignore`** so they are never committed.

---

## How to configure in CI

Set the following secrets in your CI environment (e.g. GitHub Actions secrets):

- `SUPABASE_PROJECT_URL`
- `SUPABASE_ANON_KEY`

Inject them into the build using `-xcconfig` or `INFOPLIST_FILE_KEY` arguments:

```yaml
- name: Build
  run: |
    xcodebuild \
      -scheme CathedralOSApp \
      SUPABASE_PROJECT_URL="${{ secrets.SUPABASE_PROJECT_URL }}" \
      SUPABASE_ANON_KEY="${{ secrets.SUPABASE_ANON_KEY }}"
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
- **Anon key** — the public Supabase key. Safe to embed in the app binary.
  Used in the `apikey` header for Edge Function and REST API calls.
- **User JWT** — the Supabase access token issued at sign-in. Stored in the
  iOS keychain. Sent as the `Authorization: Bearer <token>` header for
  user-scoped REST API calls protected by Row-Level Security.
- **Refresh token** — stored in the iOS keychain. Used to renew the access
  token without requiring the user to sign in again.
- **Do not commit** any of the above to version control. Use `.xcconfig` files
  (gitignored) or CI secrets for build-time injection.
