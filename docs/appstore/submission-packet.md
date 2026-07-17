# Earshot 1.0 App Store submission packet

This is the master index for the Earshot 1.0 submission. Detailed copy remains
in the linked files so one canonical source is used for each App Store field.

## Completed and verified

- Integration/default branch: `swift`
- Version: 1.0.0 (build 150 until the release archive increments it)
- Bundle ID: `media.payown.earshot`
- Device family: iPhone only
- Minimum iOS version: iOS 17
- Privacy Policy: https://payown.media/earshot-privacy-policy/
- Support: https://payown.media/earshot-support/
- Terms: Apple's Standard EULA
- App Privacy response published July 16, 2026: **No, we do not collect data
  from this app**
- Release configuration compiles successfully
- Full automated suite: 1,380 tests, 14 known StoreKit quarantines, 0 failures
- Large-library performance fixes verified with VoiceOver on Michael's device

## Canonical submission materials

- Store listing text: `docs/appstore/store-listing.md`
- App Privacy answers: `docs/appstore/privacy-nutrition-label.md`
- URLs: `docs/appstore/app-store-urls.md`
- Purchase disclosures: `docs/appstore/purchase-disclosures.md`
- Screenshot inventory: `docs/appstore/screenshots.md`
- Privacy Policy WordPress source:
  `docs/privacy/earshot-privacy-policy-wordpress.txt`
- Support WordPress source: `docs/support/earshot-support-wordpress.txt`

## App Store Connect actions remaining

- [x] Publish App Privacy answer: **No, we do not collect data from this app**
- [ ] Enter the Privacy Policy and Support URLs from `app-store-urls.md`
- [ ] Approve and enter the listing text
- [ ] Complete the age-rating questionnaire
- [ ] Upload the final iPhone screenshot set
- [ ] Confirm Paid Apps Agreement, banking, and tax setup are active
- [ ] Confirm all Earshot Plus and tip products are cleared for submission
- [ ] Enter App Review contact information and reviewer notes
- [ ] Attach the In-App Purchases/subscriptions to version 1.0 for review

## Release validation remaining

- [ ] Complete human sandbox purchase testing: monthly, yearly, lifetime,
      restore, cancellation, lapse/expiration, pending purchase, and all tips
- [ ] Complete final VoiceOver walkthrough of every screen
- [ ] Verify cold launch, background audio, lock-screen controls, downloads,
      OPML import/export, and recovery after force quit
- [ ] Create a signed Release archive from `swift`
- [ ] Run Apple's archive validation and resolve every blocking warning
- [ ] Submit the archive and attached purchases for App Review

## Deferred beyond 1.0

- iPad support and iPad screenshots
- Swift 6 language-mode migration
- Marketing URL unless a dedicated Earshot marketing page is published
