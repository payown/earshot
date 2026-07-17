# App Store Connect "App Privacy": Final Recommended Answers

Final engineering recommendation for issue #646, based on Apple's current
App Privacy definition, the published Earshot Privacy Policy, the privacy
manifest, and a direct source review. Michael remains responsible for the
final legal/compliance submission in App Store Connect.

**Published in App Store Connect on July 16, 2026:** No, we do not collect
data from this app.

Structured to match App Store Connect's questionnaire flow: for each of
Apple's data categories, the app asks (1) is data of this type collected,
(2) if yes, is it linked to the user's identity, (3) is it used for
tracking, (4) what is it used for.

## How to read "Collected"

Apple defines collection as transmitting data off the device in a way that
lets the developer or an integrated third-party partner access it for longer
than necessary to service a request in real time. Apple also says on-device
processing is not collection and developers are not responsible for declaring
data collected by Apple. Earshot has no backend or integrated analytics,
advertising, crash-reporting, or tracking SDK.

## Exact App Store Connect selection

Select **No, we do not collect data from this app**, then save. App Store
Connect should not present individual data-category questions after that
selection.

Authoritative Apple references:

- https://developer.apple.com/app-store/app-privacy-details/
- https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy

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
| Purchases | No | N/A | N/A | N/A |
| Usage Data | No | N/A | N/A | N/A |
| Diagnostics | No | N/A | N/A | N/A |
| Other Data | No | N/A | N/A | N/A |

Details for every category follow, including the reasoning for each "Not
Collected" answer.

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

## Purchases: Not Collected

StoreKit provides locally verified product and entitlement information to the
app. Earshot reduces that information to on-device entitlement state and never
uploads product IDs, transaction state, expiration/revocation dates, receipts,
or purchase history to Payown Media. Apple's guidance says developers are not
responsible for declaring data collected by Apple. Payment information entered
outside the app and never available to the developer also does not need to be
declared.

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

1. In App Store Connect, open **App Privacy** and choose **Get Started**.
2. Select **No, we do not collect data from this app** and save.
3. Set the Privacy Policy URL to
   `https://payown.media/earshot-privacy-policy/`.
4. Leave the optional Privacy Choices URL blank because Earshot holds no
   server-side user data to access, change, or delete.
5. **Completed July 16, 2026:** privacy response published and recorded in
   the submission packet.
