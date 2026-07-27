# Agent Operating Rules

## Workflow
1. Read the task.
2. Inspect the relevant files.
3. Make the smallest safe change. Preserve existing work.
4. Run the repo-local validation in **Repo Notes** below.
5. Report files changed, validation performed, and any risks or follow-ups.
   Do not commit, push, open a PR, branch, create a worktree, or touch
   unrelated files unless the user explicitly asks for the action by name.

## Approval Gates
The agent may make local file edits, run the validation commands below, and
read project state freely.

The agent may NOT do any of the following unless Kevin gives a separate
explicit approval naming the action and target:
- merge a PR
- delete a remote branch
- delete a local worktree
- run a release/build/deploy workflow
- deploy or submit to TestFlight or any app store
- modify signing, certificates, provisioning, Fastlane match storage,
  secrets, tokens, or environment files

## Hard Limits
- Do not touch certificate repositories.
- Do not make destructive data changes unless explicitly instructed.
- Do not merge or deploy without explicit approval.

## Repo Notes
CathedralOS is an iOS Swift/SwiftUI app with a checked-in `CathedralOSApp.xcodeproj`.
It includes app code under `CathedralOSApp/`, tests under `CathedralOSAppTests/`,
and Supabase backend artifacts under `supabase/`.

When available on a suitable macOS/Xcode host, prefer repo-local validation
such as:
- `xcodebuild build -project CathedralOSApp.xcodeproj -scheme CathedralOSApp -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO`
- `xcodebuild test -project CathedralOSApp.xcodeproj -scheme CathedralOSApp -sdk iphonesimulator -destination "platform=iOS Simulator,OS=latest,name=iPhone 16" CODE_SIGNING_ALLOWED=NO`

Do not add real Supabase keys, modify committed secrets, run release
workflows, submit builds, or change signing/certificate/provisioning files
without explicit approval.
