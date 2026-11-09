# Private TestFlight build 316 — November 9, 2026

Earshot **1.2.6 (316)** was archived from clean linked branch commit
`b4fa1466a69cd15cffa27876bffae103b452a28c`. PR #1063 merged as
`ca9f7b04d32bf411e126a86eb5a0c6730126e3f1`; the two commits have
identical source trees. This candidate includes Watch transfer crash fix #1062
at `336412e7`. The signed build 316 Watch dSYM contains an explicit
`@Sendable` handoff reply handler; the three build 315 physical crash reports
symbolicated to the previous unannotated callback. See
[the crash analysis](../watchos-transfer-crash-315.md).

Required PR #1063 Swift CI run 42627910164 passed **2,749 unit tests and 41 UI
tests**, zero failures, with 34 unit and 8 UI scheme skips. The Watch-specific
fix passed 47 unit and 5 UI tests locally on a watchOS 27.2 simulator. The
two StoreKit simulator suites and two methods reproduced on unchanged build
313 remain excluded as documented in [the 314 quality report](../watchos-playback-quality-314.md).

The Release archive `/tmp/EarshotWatch316Signed.xcarchive` and App Store
export `/tmp/EarshotWatch316Export/Earshot.ipa` succeeded using command-line
signing overrides and the existing App Store profiles. The exported IPA's
iPhone, independent Watch app and Watch widget all report **1.2.6 (316)** and
pass strict signature verification. The Watch has the approved App Group and
CloudKit entitlements, production iCloud environment and
`get-task-allow=false`. No project signing settings or entitlements changed.
The IPA SHA-256 is
`6087a6311421238e627a41319d4b8c59d5649f2c52ec6535a951b9b07abce8fa`.
The Watch arm64 dSYM UUID is `ED62B668-A448-35F7-B61A-0610BFAB0DD4`.

App Store Connect build `4d8f806f-74b5-4f56-b851-58a91a347302` has upload
`COMPLETE`, processing state `VALID`, and internal state `IN_BETA_TESTING`.
The complete build-group lookup returned only the existing **Internal Testing
Group**, with all-build access and seven installed testers. Michael explicitly
authorized this group for build 316. External state is
`READY_FOR_BETA_SUBMISSION`; no Public Testers group was assigned and no App
Store release was made. The all-build group was already enabled, so the CLI
skipped duplicate group assignment. `autoNotifyEnabled` is true, but no
separate notification was requested or individual delivery verified.

Live en-US What to Test matches the Michael-approved [Chapter 121](../kashe.md)
and `build-316-notes.txt` apart from App Store Connect removing the file's
final newline. The earlier empty `AWAITING_UPLOAD` reservation for 316 still
has no uploaded files; the completed build has a separate upload record.

Physical acceptance remains open. Update iPhone and Watch in place, repeat
phone-to-Watch transfer at 1x and 1.5x with the phone foregrounded and
backgrounded, and compare the last/first words and positions. The Watch app
must stay open and the phone must stop only after Watch audio starts. Also
verify VoiceOver Magic Tap and the earlier iPhone Watch-open crash regression.
Start Testing issue `6a93fde4-e2f9-4aee-ac97-b3b9f536da4d` remains in
testing until Michael accepts the physical check. Moving a paused phone
episode to Watch still requires starting phone playback first; immediate
paired Queue snapshots remain disabled. This internal build is not public
beta or version 1.3 approval.
