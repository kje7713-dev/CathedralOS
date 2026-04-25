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

All future backend calls (generation, sharing, usage sync) will flow through
this layer. No existing local-only flows are broken by its presence.
