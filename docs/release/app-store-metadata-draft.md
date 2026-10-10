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

## URLs — operator input required

- Privacy Policy URL: **NEEDS OPERATOR**
- Terms of Use / EULA: **NEEDS OPERATOR**
- Support URL: **NEEDS OPERATOR**

Do not replace these with placeholders. The release workflow requires production
privacy and terms URLs to be real HTTPS URLs.

## Review notes — draft

StoryDonkey is a writing workspace for developing characters, settings,
relationships, themes, motifs, story arcs, and generated prose.

The reviewer can create a project, add story material, sign in with Apple, and use
the generation flow after backend configuration is available. Generated writing is
requested through the StoryDonkey backend; the OpenAI credential is never shipped
in the app. The Account area includes Diagnostics, Restore Purchases, and account
deletion. Subscription and credit purchases are handled through StoreKit.

Provide the App Review demo account and any required sandbox purchase instructions
in App Store Connect before submission: **NEEDS OPERATOR**.

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

## Remaining release metadata checklist

- App Store screenshots: **NEEDS OPERATOR**
- Age rating and content declarations: **NEEDS OPERATOR**
- App privacy questionnaire: **NEEDS OPERATOR** after final data-use review
- Sign in with Apple capability and review path: **NEEDS OPERATOR verification**
- Banking, tax, and paid-app agreements: **NEEDS OPERATOR**
- Final TestFlight build selection: **NEEDS OPERATOR**
