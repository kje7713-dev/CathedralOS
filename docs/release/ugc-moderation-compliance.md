# StoryDonkey UGC compliance

StoryDonkey uses a minimal public-sharing safety layer. It is not a general moderation system.

| Requirement | Implementation |
| --- | --- |
| Pre-post filtering | Each section processed by the existing embedding lifecycle is checked with OpenAI `omni-moderation-latest`; only `sexual/minors` can make it ineligible for public sharing. |
| Reporting | Existing authenticated `shared_output_reports` flow remains in place. A best-effort Resend alert includes report ID, shared-output ID, reason, and timestamp. |
| Blocking | `user_blocks` stores a unique authenticated blocker/blocked pair. Public list/detail reads exclude blocked creators; Account exposes unblock actions. |
| Response | Reports remain persisted if email fails. The operator can manually unpublish through the existing secure service-role/operator database path, for example by setting `visibility = 'private'` and `unpublished_at = now()` on the verified `shared_outputs.id`; no service-role capability is exposed to ordinary clients. |
| Contact | Paywall exposes the configured HTTPS `SUPPORT_URL`. The release workflow requires it. |

Eligibility is calculated after the existing section embedding is saved. The section stores the current content hash, result, checked time, and the one possible restriction reason. A changed section receives a new check during its next embedding operation.

Private writing, generation, editing, saving, cloud sync, embeddings, private EPUB creation/export, and subscriptions are not restricted. The result affects only StoryDonkey public publication. Public EPUB publication and ordinary public sharing remain supported; they fail closed only when required current section eligibility is missing or restricted. Public novels reuse current section results rather than rescanning a complete book.

The app displays `Public Sharing: Checking…`, `Public Sharing: Eligible`, `Public Sharing: Restricted`, or `Public Sharing: Not yet checked` beside outline sections. Restricted sections explain that the restriction affects public sharing only, not private writing or export.

## Production configuration

Set the following Supabase secrets for report email delivery:

- `RESEND_API_KEY`
- `OPERATOR_ALERT_EMAIL`
- `OPERATOR_ALERT_FROM_EMAIL`

Set the following GitHub Actions secret before an iOS release:

- `SUPPORT_URL` — a real public HTTPS support/contact page

No production support address is invented in source.
