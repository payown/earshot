# App Store Connect "App Privacy" (Nutrition Label): Draft Answers

Drafted for issue #646. **This is a draft for Michael's review, not a final
submission.** Engineering compiled these answers from the current privacy
policy (`docs/privacy/index.html`, effective July 2, 2026) and a direct
read of the app's source, listed per category below. Michael is the one
submitting to Apple and is the only person who can make the final
legal/compliance call on each answer. Treat everything here as "what the
code actually does today," not as pre-cleared copy.

Structured to match App Store Connect's questionnaire flow: for each of
Apple's data categories, the app asks (1) is data of this type collected,
(2) if yes, is it linked to the user's identity, (3) is it used for
tracking, (4) what is it used for.

## How to read "Collected"

Apple's definition of "collected" is data transmitted off the device to
Payown Media or a third party. Data that stays entirely on-device (SwiftData
store, `UserDefaults`/`AppSettingsStore`) is not "collected" under Apple's
definition even though the app reads and writes it locally. That's why
almost every category below is "Not Collected" despite the app storing
plenty of state (subscriptions, queue, playback position, bookmarks) on the
device.

## Summary

The table below lists, for each Apple privacy category, whether Earshot collects that data, whether it is linked to identity, whether it is used for tracking, and the purpose if collected.

| Category | Collected? | Linked to identity? | Used for tracking? | Purpose |
| --- | --- | --- | --- | --- |
| Contact Info | No | N/A | N/A | N/A |
| Health & Fitness | No | N/A | N/A | N/A |
| Financial Info | No | N/A | N/A | N/A |
| Location | No | N/A | N/A | N/A |
| Sensitive Info | No | N/A | N/A | N/A |
| Contacts | No | N/A | N/A | N/A |
| User Content | No | N/A | N/A | N/A |
| Browsing History | No | N/A | N/A | N/A |
| Search History | No | N/A | N/A | N/A |
| Identifiers | No | N/A | N/A | N/A |
| Purchases | **Yes** | No | No | App Functionality |
| Usage Data | No | N/A | N/A | N/A |
| Diagnostics | No | N/A | N/A | N/A |
| Other Data | No | N/A | N/A | N/A |

Details for every category follow, including the reasoning for each "Not
Collected" (so Michael can sanity-check the "no" answers, not just take them
on faith) and the full detail for Purchases.

---

## Contact Info: Not Collected

No account, no sign-in, no name/email/phone number field anywhere in the
app. The Send Feedback screen composes an email via the user's own Mail app
(`MFMailComposeViewController`, `EarshotSwift/Earshot/Features/Settings/Presentation/SendFeedbackView.swift`)
or a `mailto:` fallback. The user's device sends that email through their
own mail account, the same as tapping any other `mailto:` link on the web.
Earshot's code never transmits it anywhere itself. (See the "Worth flagging"
note below. This is the one borderline case in an otherwise clean sheet.)

## Health & Fitness: Not Collected

No HealthKit, no fitness/workout data, nothing in this category applies to
a podcast player.

## Financial Info: Not Collected

No payment card numbers, bank info, or credit info ever reach Earshot's
code. Apple's StoreKit handles 100% of payment processing for Earshot Plus
and the tip jar; see **Purchases** below for what Earshot's own code does
see.

## Location: Not Collected

No `CoreLocation` usage anywhere in the codebase, no location permission
requested.

## Sensitive Info: Not Collected

No race, sexual orientation, religion, biometric data, etc. collected.

## Contacts: Not Collected

No access to the user's address book/contacts.

## User Content: Not Collected

Subscriptions, queue, folders, bookmarks, and listening history are all
stored locally on-device only (SwiftData) and never uploaded to Payown
Media or any third party, per the privacy policy and confirmed by the
architecture. There is no backend Earshot talks to for user data at all.

## Browsing History: Not Collected

No web browsing tracked. In-app web views (e.g. show notes links) don't
report browsing activity anywhere.

## Search History: Not Collected

Podcast directory searches go straight from the device to the public
podcast search API/index the user is querying (per the privacy policy's
"Network connections" section). Earshot's own servers never see or log
search terms because Earshot doesn't operate a backend at all.

## Identifiers: Not Collected

Checked explicitly for this issue: no `identifierForVendor`,
`ASIdentifierManager`/IDFA, or any persistent device identifier is read,
stored, or transmitted anywhere in the codebase. The only device-related
value touched is `UIDevice.current.systemVersion` (iOS version string, e.g.
"17.4") plus a hardware model string, used solely inside the user-initiated
feedback-email body (`FeedbackComposer.swift`), not a persistent
identifier, not collected/transmitted by Earshot's own code, and only
included if/when the user chooses to send feedback. No advertising
identifiers exist because there are no ads. **This matches the CLAUDE.md/
privacy-policy claim of "no advertising identifiers, no third-party
trackers" with no discrepancy found.**

## Purchases: Collected (App Functionality only)

This is the one real entry, added because of the Earshot Plus and tip jar
StoreKit work (#631/#632/#633/#634/#635/#636).

- **Data collected:** Purchase history, specifically StoreKit 2 product
  IDs (e.g. which Earshot Plus tier or tip amount), transaction
  verification state, and expiration/revocation dates for subscriptions.
  Confirmed by reading the actual purchase code:
  - `EntitlementTransactionSource.swift` / `StoreKitEntitlementSource`: the
    only type that touches `Transaction.currentEntitlements` and
    `Transaction.updates`. It reduces every result to a
    `RawTransactionResult` carrying only `productID`, verification
    outcome, and `revocationDate`/`expirationDate`. No card data and no
    billing address ever come through this type. The file's
    own doc comment states: "No backend, no server-side receipt validation
    anywhere in this codebase... every transaction is checked with local,
    on-device StoreKit 2 cryptographic verification only."
  - `TipPurchaseSource.swift` / `StoreKitTipPurchaseSource`: same pattern
    for one-time tip purchases. It reduces `Product.purchase()`'s result to a
    `RawPurchaseResult` with just `productID` and verification
    outcome/reason. Same "no backend, no server-side receipt validation"
    comment.
  - `EntitlementStore.swift`: persists only a boolean (`isEntitled`) and a
    last-synced timestamp locally via `AppSettingsStore` (on-device
    SwiftData-backed settings), which is what "remembers" that Plus is
    active across launches. It is never uploaded anywhere.
  - **Confirms the issue's claim:** Apple's StoreKit does 100% of payment
    processing. Earshot's code never sees a card number, billing address,
    or any other payment credential; only product IDs and
    verification/entitlement state, all processed and stored on-device.
- **Linked to your identity?** No. Nothing here is tied to a Payown Media
  account (none exists) or any Earshot-side user identifier. The only
  "identity" involved is the user's own Apple ID, which is entirely
  Apple's/StoreKit's concern, not data Earshot links anything to.
- **Used for tracking?** No. Never shared with a third-party data broker or
  advertising network, never combined with data from other apps/companies.
- **Purpose:** App Functionality only: restoring/verifying the Earshot
  Plus entitlement (unlock unlimited subscriptions) and completing tip jar
  purchases. Not used for analytics, advertising, or any other purpose.

## Usage Data: Not Collected

No analytics SDK anywhere in the app (confirmed; see "Discrepancy check"
below). No product interaction data, no advertising data, no other usage
data collected or transmitted.

## Diagnostics: Not Collected

No crash reporter anywhere in the app (confirmed below). No crash logs,
performance data, or other diagnostic data leave the device.

## Other Data: Not Collected

Nothing else fits Apple's catalog of data types.

---

## Discrepancy check: CLAUDE.md vs. actual code

CLAUDE.md's non-negotiable rule #4 says: "Minimum data collection. Crash
reports and analytics are opt-out and anonymized. Listening history is
user-controlled. No third-party trackers, no advertising IDs."

Read literally, "opt-out" implies a crash/analytics SDK exists and defaults
to on. **That is not what's actually in the codebase.** What's really there:

- `grep -rli "sentry|crashlytics|analytics|firebase"` across
  `EarshotSwift/Earshot/` turns up exactly three files, and all three are
  just user-facing *copy* stating that no analytics/crash reporting
  exists, not an SDK:
  - `Features/Settings/Presentation/PrivacySettingsView.swift`: "No crash
    reporting, no analytics, no third-party trackers, no advertising IDs."
  - `Features/Onboarding/Domain/OnboardingContent.swift`: same claim, in
    onboarding copy.
  - `Data/Persistence/AppSettingsStore.swift`: defines
    `crash_reporting_enabled` / `analytics_enabled` setting keys, but its
    own comment says: *"retained for data compatibility only. No crash
    reporter or analytics SDK ships in the app"*; these keys exist purely
    so old persisted settings values don't error on load; nothing reads
    them to gate any actual telemetry.
- No `Package.resolved` exists anywhere in the repo; there are zero Swift
  Package Manager third-party dependencies at all, which rules out Sentry,
  Crashlytics/Firebase, or any other analytics/crash SDK by construction.
- No `import Sentry`, `import FirebaseCrashlytics`, or similar anywhere in
  the codebase.

**Conclusion:** this is CLAUDE.md describing a policy for a feature that was
never built (or was deliberately dropped in favor of "ship nothing"), not a
case of undisclosed telemetry running today. The privacy policy's "there is
no crash reporter in the app" / "there is no analytics SDK in the app" is
accurate as of this codebase. Michael should consider updating the CLAUDE.md
wording (drop "are opt-out and anonymized," since there's nothing to opt out
of). Flagging it here rather than editing CLAUDE.md myself, since that's
outside this issue's scope.

## DECIDED: Send Feedback email diagnostics stay OUT of the nutrition label

**Michael's decision, 2026-07-10:** the Send Feedback email device info is
deliberately NOT declared in the App Privacy nutrition label. Reasoning
(settled — do not re-litigate on future updates): the info is composed into an
email in the user's own Mail app and only sent if the user themselves taps
Send. User-initiated email content that the person reviews and sends from their
own mail account is not app-collected data under Apple's definition, so it
needs no nutrition-label entry. This note is recorded here so future submission
updates don't second-guess the call. The analysis that led to it is preserved
below for reference.

---

**Send Feedback email diagnostics (analysis).** `FeedbackComposer.swift` appends an
"anonymized system info" block (app version, build number, iOS version,
device model string) to the feedback email body when the user opts in.

It then hands the whole thing to `MFMailComposeViewController` (or a
`mailto:` fallback) for the user to review and send from their own Mail
account. Earshot's own code never transmits this anywhere. It only builds
the text and hands off to the system mail composer.

This is the same pattern as any website's "mailto:" support link. Data
handed to a share-sheet or mail composer that the user reviews and sends
themselves isn't the app "collecting" it, so I don't believe Apple's
guidance requires declaring it. But it's the one place device info leaves
the device via anything Earshot's code touches, so it's flagged here rather
than silently assumed away.

If Michael wants to be maximally conservative, this could be mentioned in
the privacy policy's "what stays on device" section, even though it likely
doesn't need its own nutrition-label entry.

## Next steps

1. Michael reviews every row above against actual App Store Connect wording
   (Apple's category/purpose option lists don't always map 1:1 to this
   summary, so transcribe carefully).
2. Confirm the Purchases entry once more right before submission, in case
   any monetization code changes between now and the App Store 1.0 launch
   milestone closing.
3. ~~Decide on the Send Feedback diagnostics question.~~ DECIDED 2026-07-10:
   stays out of the nutrition label (see the DECIDED section above).
4. Submit in App Store Connect, then update this file (or note in the PR)
   with the final submitted answers for the record.
