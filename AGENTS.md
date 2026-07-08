# Agent Operating Rules

## Required Workflow
For every coding task:
1. Work in an isolated worktree under `/home/kevbot/agent-worktrees/<RepoName>/<task-slug>`.
2. Use a branch named `agent/<task-slug>`.
3. Never work directly on `main` or the default branch.
4. Inspect relevant files before editing.
5. Prefer the smallest safe change.
6. Run available repo-local validation.
7. Commit changes.
8. Push the branch.
9. Open a pull request against the default branch.
10. Report PR URL, files changed, validation performed, and risks.

## Approval Gates
The agent may create branches, commits, pushes, and pull requests during assigned repo tasks.

The agent may NOT do any of the following unless Kevin gives a separate explicit approval message naming the action and target PR or workflow:
- merge a PR
- delete a remote branch
- delete a local worktree
- run a release/build/deploy workflow
- deploy
- submit to TestFlight or any app store
- modify signing/certificate/provisioning/secrets

Valid approval examples:
- "Merge PR #261 and delete the branch."
- "Run the iOS build workflow for PR #261."
- "Close PR #260 and delete the branch."

Invalid approvals:
- "looks good"
- "worked"
- "continue"
- "nice"
- "ship it" unless it names the exact PR/action

## Hard Limits
Do not touch certificate repositories.
Do not change signing, certificate, provisioning, Fastlane match storage, secrets, tokens, or environment files unless explicitly instructed.
Do not make destructive data changes unless explicitly instructed.
Do not merge or deploy without explicit approval.

## Pull Request Expectations
Every PR should include:
- Summary
- Files changed
- Validation performed
- Known risks
- Manual test notes when full validation is not possible locally

## Repo Notes
CathedralOS is an iOS Swift/SwiftUI app with a checked-in `CathedralOSApp.xcodeproj`. It includes app code under `CathedralOSApp/`, tests under `CathedralOSAppTests/`, and Supabase backend artifacts under `supabase/`.

When available on a suitable macOS/Xcode host, prefer repo-local validation such as:
- `xcodebuild build -project CathedralOSApp.xcodeproj -scheme CathedralOSApp -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO`
- `xcodebuild test -project CathedralOSApp.xcodeproj -scheme CathedralOSApp -sdk iphonesimulator -destination "platform=iOS Simulator,OS=latest,name=iPhone 16" CODE_SIGNING_ALLOWED=NO`

Do not add real Supabase keys, modify committed secrets, run release workflows, submit builds, or change signing/certificate/provisioning files without explicit approval.
