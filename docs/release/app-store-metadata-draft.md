# StoryDonkey App Store Metadata Working Draft

This is a preparation document only. It is not an App Store Connect submission and
contains no fabricated legal URLs or credentials.

## Store listing copy — en-US

| Field | Draft | Status |
|---|---|---|
| Name | StoryDonkey | Existing checked-in value |
| Subtitle | From story spark to final page | Approved draft; saved in `fastlane/metadata/en-US/subtitle.txt` |
| Promotional text | Build the characters, worlds, and story structure behind your next great idea. | Approved draft; saved in `fastlane/metadata/en-US/promotional_text.txt` |
| Description | See `fastlane/metadata/en-US/description.txt`. | Existing draft; review before apply |
| Keywords | See `fastlane/metadata/en-US/keywords.txt`. | Existing draft; review before apply |

## URLs and synchronization status

- Privacy Policy URL: **checked in and applied by the metadata lane**
- Support URL: **checked in and applied by the metadata lane**
- Terms of Use URL: **checked in; use Apple standard EULA; leave custom EULA blank**

Do not replace these with placeholders. The release workflow requires production
privacy and terms URLs to be real HTTPS URLs. Run the read-only App Store audit
after every apply; it is the source of truth for ASC-vs-repository matches.

## Review notes — draft

StoryDonkey is a writing workspace for developing characters, settings,
relationships, themes, motifs, story arcs, and generated prose.

The reviewer can create a project, add story material, sign in with Apple, and use
the generation flow after backend configuration is available. Generated writing is
requested through the StoryDonkey backend; the OpenAI credential is never shipped
in the app. The Account area includes Diagnostics, Restore Purchases, and account
deletion. Subscription and credit purchases are handled through StoreKit.

App Review access is documented in
[`app-review-access-howto.md`](app-review-access-howto.md). The reviewer signs in
with Sign in with Apple; a separate Sandbox Apple Account is only for StoreKit
purchase testing. Enter any private credentials directly in App Store Connect,
never in this repository. Status: **NEEDS OPERATOR**.

## StoreKit products to configure and verify

| Product ID | Type | Draft display meaning |
|---|---|---|
| `cathedralos.pro.monthly` | Auto-renewable subscription | Monthly Pro plan; 100 monthly credits |
| `cathedralos.credits.small` | Consumable | Small credit pack; 20 credits |
| `cathedralos.credits.medium` | Consumable | Medium credit pack; 60 credits |
| `cathedralos.credits.large` | Consumable | Large credit pack; 150 credits |
| `cathedralos.credits.xlarge` | Consumable | Extra-large credit pack; 400 credits |

Approved App Store Connect price points: Pro monthly **$4.99**, small **$0.99**,
medium **$2.99**, large **$6.99**, extra-large **$14.99**. Configure and verify
product names, prices, availability, review screenshots, and subscription group
settings in App Store Connect: **NEEDS OPERATOR**.

## Age rating and content declaration — proposed values

Recommended store rating: **13+** under Apple’s current rating model, or the
regional equivalent shown by App Store Connect.

The questionnaire should document the app’s actual capabilities, not only the
safest example output:

- Public user-created/shared content: **Yes**
- General manuscript or arbitrary-file upload: **No**
- AI-generated writing: **Yes**
- Romantic/sexual themes: **Infrequent/Mild**; the model does not intentionally render explicit sex
- Violence, horror, and disturbing mature themes: **Infrequent/Mild**, unless production behavior demonstrates otherwise
- Sexual content involving minors: **No; blocked by the public-sharing safety gate**
- Gambling, real-money gaming, or unrestricted web access: **No**

The reviewed declaration is submitted by the explicit `age_rating` workflow mode;
that mode is a protected App Store Connect write.

## Remaining release metadata checklist

- Read-only ASC audit after the next metadata apply: **AUTOMATED; required for verification**
- Custom App Store EULA: **intentionally blank; Apple standard EULA selected**
- Additional screenshot display sizes or localizations, if required: **OPERATOR review**
- Age rating and content declarations: **13+ / infrequent-mild documented; submit via explicit age_rating workflow**
- App privacy questionnaire: **OPERATOR review** after final data-use review
- App Review contact, demo account, and purchase instructions: **OPERATOR input**
- Sign in with Apple capability and review path: **OPERATOR verification**
- Banking, tax, and paid-app agreements: **OPERATOR-only**
- Final build selection and submission: **OPERATOR decision**
