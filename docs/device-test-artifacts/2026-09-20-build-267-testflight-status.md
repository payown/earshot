# Build 267 TestFlight status

- Version: 1.2.3 (267).
- Archived source: `41ad72c91a0f31971e945538684c4970bd27df09`, release packaging PR #980. App changes merged through PR #979 (`8dc490f9`).
- App Store Connect build: `9cae8cad-a327-416b-ad2f-dbecc9162eff`.
- Processing: VALID.
- Internal Testing Group: IN_BETA_TESTING; explicit and all-build membership verified.
- Public Testers: IN_BETA_TESTING; explicit membership verified.
- Automatic tester notifications are enabled. API confirmation establishes configuration, not individual email delivery.
- en-US What to Test matches the complete Kashe Chapter 89 in `docs/testflight/build-267-notes.txt` and `docs/kashe.md`; Apple trims the final newline. What to try precedes the story, which ends the notes.
- Xcode 27.0 Release archive, automatic-signing export, archive signature verification, and exported IPA version verification passed.
- PR #979 CI passed. Local app regression run reported 2,382 tests, 29 skipped, no failures, with the documented StoreKit exclusions. Michael confirmed the four requested phone checks passed before authorizing distribution.
- BBC insecure redirects remain a high-priority open issue and are disclosed in testing notes.

No App Store release submission was performed.
