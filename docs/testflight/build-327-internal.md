# Earshot 1.2.6 (327) TestFlight receipt — 2026-11-17

Build 327 reached the existing internal group on November 16 and the existing
Public Testers group on November 17. It is not an App Store release.
Its signed binary came from commit `eb3c10e935ffe7ccbcb40904dc0b3e4ade9963c4`
on `test/earshot-internal327-20261116`. This branch combines ready-for-review
PRs #1085 (folder podcast navigation), #1086 (onboarding and help), #1087
(stale Inbox batch selection), and #1088 (activation-time scope guard, stacked
after #1087). At the November 17 check, all four PRs were ready for review,
open, and unmerged.

## Source and artifact

- Exact-source Swift CI: [run 43888168884](https://github.com/payown/earshot/actions/runs/43888168884), success.
- iPhone simulator full scheme: 2,817 unit tests, 34 skips, zero failures;
  55 UI tests, 11 skips, zero failures (`/tmp/earshot327-iphone-full.xcresult`).
- Watch simulator full scheme: 55 unit and 8 UI tests, zero skips or failures
  (`/tmp/earshot327-watch-full.xcresult`).
- Focused iPhone checks: 6 passed. The iPadOS 27.2 Inbox VoiceOver selection
  automation passed. An exploratory iPadOS 26.0 run of seven cases had four
  passes, one iOS 27-only skip, and two iPhone-navigation setup failures;
  those two cases passed on iPhone. Preserve the exploratory failure record at
  `/tmp/earshot327-ipad-focused.xcresult`; it is not a passing iPad suite.
- Archive: `/tmp/Earshot327-eb3c10e9.xcarchive`, version 1.2.6, build 327,
  bundle `media.payown.earshot`, app dSYM UUID
  `09B3EED9-49F9-3A69-85AF-958DB5366802`.
- Exported IPA: `/tmp/Earshot327-eb3c10e9-export/Earshot.ipa`, SHA-256
  `13475a0bfa1dc3bee156eabdd0bafec88ba1de1123ebcd48b2e21da2b29ebdce`.
  ASC did not supply an upload checksum; the local artifact hash is retained.

## App Store Connect

- Uploaded once: upload/build ID `7d11876f-39b4-40dd-9312-bd887c67b0c9`,
  file ID `4e358e9e-5516-496b-b2c3-95cf5ea78c99`; processing `VALID`.
- Chapter 131 en-US What to Test notes are content-equivalent to
  [build-327-notes.txt](build-327-notes.txt); ASC omits its final newline.
- Internal build state: `IN_BETA_TESTING`. The existing Internal Testing Group
  `0d4027e4-f63b-4798-a882-5c8c29b16d89` has seven testers and
  `hasAccessToAllBuilds=true`.
  A manual add to this group was rejected with HTTP 422 because ASC cannot
  explicitly assign this all-builds internal group. No retry was made.
- On November 17 the existing Public Testers group
  `9a7512e9-a451-4917-9554-51931777c252` was added to this same build.
  Apple beta review is `APPROVED`; external build state is `IN_BETA_TESTING`.
  ASC lists exactly these two groups. `autoNotifyEnabled=true` does not
  establish delivery of any individual notification.
- Xcode export created an unused `AWAITING_UPLOAD` reservation
  `a7b184a8-fb2e-4c2d-9cbd-a8f0f7b18baf` with zero files. Earlier exports
  for builds 324 and 326 show the same separate reservation pattern. The
  completed upload above is the only build 327 binary upload.

## Remaining acceptance

Michael subsequently reported that the build 327 checklist tasks passed.
Record this as his scoped acceptance of the folder and iPad Inbox checks in the
[detailed device test plan](build-327-device-test-plan.md), not as proof of an
optional fresh-install ten-page onboarding test or every unmentioned device,
OS, or batch action. Two-device Inbox differences, Folder Run playback, and
the unresolved build 324 crash remain separate checks. Do not restore
historical ambiguous dismissals. The four Watch scenarios Michael accepted on
build 326 are not claimed as new build 327 tests.

## Main integration gate

`main` requires linear history and the `Build and test (EarshotTests)` check;
the protected branch requires zero GitHub approval reviews. Individual PR
checks and the combined build 327 source CI passed. The first normal merge
attempt for #1085 used a merge commit and GitHub rejected it with “Merge
commits are not allowed on this repository.” The request did not execute, and
main stayed unchanged. Do not claim a GitHub review approval or a merged PR.
The fresh-install onboarding path remains physically unverified.
