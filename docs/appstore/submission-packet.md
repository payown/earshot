# Earshot 1.1.0 App Store submission packet

This is the master index for the Earshot 1.1.0 submission. Detailed copy remains
in the linked files so one canonical source is used for each App Store field.

## Completed and verified

- Integration/default branch: `main`
- Version: 1.1.0 (build 210)
- Bundle ID: `media.payown.earshot`
- Device family: iPhone only
- Minimum iOS version: iOS 18
- Privacy Policy: https://payown.media/earshot-privacy-policy/
- Support: https://payown.media/earshot-support/
- Terms: Apple's Standard EULA
- App Privacy response published July 16, 2026: **No, we do not collect data
  from this app**
- Age rating completed July 16, 2026: **9+**
- Release configuration compiles successfully
- Supported iOS 26.5 suite: 1,874 tests, 40 intentional skips, 0 failures
- App Store Connect validation: 0 blockers
- Submitted to App Review on August 20, 2026; submission
  `04bc3d59-01d5-4aae-ab92-eead279402a1`
- Seven-day phased release configured to begin after approval
- Large-library performance fixes verified with VoiceOver on Michael's device

## Canonical submission materials

- Store listing text: `docs/appstore/store-listing.md`
- App Privacy answers: `docs/appstore/privacy-nutrition-label.md`
- URLs: `docs/appstore/app-store-urls.md`
- Purchase disclosures: `docs/appstore/purchase-disclosures.md`
- Screenshot inventory: `docs/appstore/screenshots.md`
- App Review information: `docs/appstore/app-review-information.md`
- Privacy Policy WordPress source:
  `docs/privacy/earshot-privacy-policy-wordpress.txt`
- Support WordPress source: `docs/support/earshot-support-wordpress.txt`

## App Store Connect actions remaining

- [x] Publish App Privacy answer: **No, we do not collect data from this app**
- [x] Enter the Privacy Policy and Support URLs from `app-store-urls.md`
- [x] Approve and enter the listing text
- [x] Complete the age-rating questionnaire — calculated rating: **9+**
- [x] Upload the final iPhone screenshot set
- [x] Confirm Paid Apps Agreement, banking, and tax setup are active
- [x] Confirm all Earshot Plus and tip products are cleared for submission
- [x] Enter App Review contact information and reviewer notes
- [x] Validate the In-App Purchases and subscriptions for review

Complete the purchase setup and sandbox validation before selecting the final
build or submitting version 1.0. Listing text and screenshots may be entered and
saved earlier, but the version must not be submitted until every product is
ready and attached.

## Release validation remaining

- [x] Complete human sandbox purchase testing: monthly, yearly, lifetime,
      restore, cancellation, lapse/expiration, pending purchase, and all tips
- [x] Complete final VoiceOver walkthrough of every screen
- [x] Verify cold launch, background audio, lock-screen controls, downloads,
      OPML import/export, and recovery after force quit
- [x] Create a signed Release archive from `main`
- [x] Run Apple's archive validation and resolve every blocking warning
- [x] Submit build 210 for App Review

## Deferred beyond 1.0

- iPad support and iPad screenshots
- Swift 6 language-mode migration
- Marketing URL unless a dedicated Earshot marketing page is published
