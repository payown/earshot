# Paused-player unlock investigation — October 27, 2026

Tracking: StartTesting `ec783e73-dcd7-4928-ae8d-d3f391b9e8fd`.
Source baseline: `be14c04e` (main, Earshot 1.2.5 build 279).
Branch: `codex/unlock-voiceover-279`.

## Current physical evidence

Michael paused playback with the full player open, locked his iPhone for five
seconds, unlocked, and immediately flicked with VoiceOver. VoiceOver was
unresponsive for approximately five seconds in all three attempts on build 279.
This is a user-observed duration, not a timed trace. The earlier September 25
non-reproduction on build 272 does not negate this current result.

## Measurement approach

The phone is reachable over the local network. Installed version 1.2.5 (279)
was verified with devicectl; device OS is 27.2 and host Xcode is 27.0 (27A266a).
Apple's current matrix lists Xcode 27.2 RC with the matching iOS SDK. Instruments
failed to produce a valid device trace during the previous investigation. This
pass uses an in-app diagnostic rather than claiming stack-profile evidence.

The temporary Release diagnostic is build 280, produced using a command-line
build-number override. No source version, signing configuration, capabilities,
entitlements, data schema, or accessibility semantics are changed.

`EARSHOT_UNLOCK_MEASURE=1` enables `UnlockResponsivenessProbe` for the launched
process. It records fixed-name events for application/scene/protected-data
lifecycle, VoiceOver focus and announcement completion, audio-route events,
full-player appearance, and durations for background persistence, badge loads,
search snapshot/diff/donation, cloud foreground retry, and feed refresh.

For up to 15 foreground captures, it requests a main-actor tick every 10 ms for
20 seconds, beginning at will-enter-foreground (or scene-active as fallback).
Encoding and atomic report writing run away from the main actor in one serialized
writer chain. The report is `Documents/earshot-unlock-279.json` in the app's data
container. It contains build, boolean VoiceOver/search consent state, timestamps,
durations and counts; no episode/show identifiers, spoken text, or URLs.

## Limitations

- Main-actor timer gaps include scheduler overhead and measure neither spoken
  response latency nor call stacks.
- Focus notifications can reveal focus-event timing, not the exact physical
  gesture timestamp. Correlate them with Michael's report.
- An async operation's elapsed span includes suspended time; a long span alone
  does not establish that it blocks the main actor.
- No capture covers work before the first foreground lifecycle callback.
- Diagnostic overhead and a direct development installation can affect behavior.
- Build 280 enables recording only in the explicitly launched process. Build
  281 persists the opt-in deadline for 30 minutes so normal process relaunches
  continue the same test. An explicit `EARSHOT_UNLOCK_MEASURE=0` launch clears
  the persisted opt-in. Each process also has a 30-minute recording cap.

## Device checks after installation

1. Leave the diagnostic process running. Open the full player and pause.
2. Lock five seconds, unlock, immediately flick with VoiceOver, then remain in
   Earshot at least 20 seconds. Report approximate delay and recovery.
3. Close the player and return to Library with that same episode still paused.
   Repeat lock/unlock/flick and the 20-second foreground interval as a control.
4. Retrieve the report and distinguish full-player and Library attempts using
   the appearance/disappearance events plus Michael's account.

## Installation and recorder verification

Release device build 280 succeeded under the required Xcode 27.0 toolchain.
The first two build attempts compiled successfully but failed signing because
Finder extended attributes were attached to the app under the Documents build
output. Rebuilding with `CONFIGURATION_BUILD_DIR` pointing to
`/private/tmp/earshot-unlock-280-products` succeeded. Automatic signing and the
required command-line team override were used; project signing is untouched.
`codesign --verify --deep --strict` passed.

Device installation and launch with `EARSHOT_UNLOCK_MEASURE=1` succeeded.
The installed-app query verified version 1.2.5, build 280. Retrieving the actual
report verified build 280, VoiceOver on, system search enabled, and lifecycle
events through scene-active/application-did-become-active. This is recorder
setup evidence, not an unlock reproduction or a fix.

No full regression suite was run for temporary observational instrumentation.
Existing baseline compiler warnings remain in unrelated files. No production
behavior fix, merge, App Store upload, or TestFlight distribution has occurred.
Awaiting Michael's paired full-player/Library unlock attempts and report retrieval.

## Build 280 observations and recording limitation

Michael reports approximately six seconds before the paused full player became
responsive. In Library, with the episode still paused, VoiceOver was sluggish
for four to six seconds but was not fully unresponsive. Both observations are
physical-device evidence; the exact duration is approximate.

The retrieved report contained 31 events and one 20.015-second startup capture,
ending with the first backgrounding approximately 53 seconds after probe start
and two audio route-change events. It contained no full-player appearance event
or either subsequent unlock attempt. It therefore cannot establish main-thread
or accessibility-event timing for the reported tests. Startup's largest timer
gap (276.54 ms) must not be substituted for an unlock measurement.

The reason for the missing recording is not established. Process relaunch would
disable build 280's environment-only recorder. Build 281 carries the explicit
opt-in deadline through normal relaunch, preserves the same build's recent
events/captures, and records process IDs and report-write timestamps to make
this failure visible. This changes the diagnostic, not production behavior.

## Build 281 recorder verification

Release build 281 succeeded and passed strict signature verification. Device
installation and installed-version query confirmed 1.2.5 (281). Launching with
the recording environment created process 7713 and a build-281 report with
VoiceOver enabled. A subsequent launch without that environment created process
7715 and retained both processes' start events. After the startup capture saved,
a second normal relaunch created process 7717 and retained the complete earlier
capture (1,194 ticks), verified by equality with the previously retrieved capture.
This proves cross-process opt-in and report retention on this phone. These
startup/controlled relaunch checks are not a physical unlock reproduction.

The system also supplied an Earshot disk-writes resource report timestamped
18:17 local time. Its action is explicitly `none`, and its aggregate window spans
approximately 5.2 hours, predating installation of diagnostic 280. Utility-thread
Core Data/SQLite samples are present. This is neither a kill report nor evidence
of a main-thread unlock stall; it does not establish the missing recorder's cause
or attribute its aggregate writes to diagnostic instrumentation. Raw report is
kept locally with the investigation data, not copied into an issue as user data.

## Build 281 paired unlock result

Michael reports the same delay in both repeated tests: the earlier approximate
six-second player delay and four-to-six-second Library sluggishness recur.
The final report now contains the actual full-player appearance/disappearance
and both foreground returns in process 7717, with VoiceOver enabled. Five
captures are present: two controlled startup checks, one 87-ms lock-transition
activation blip, the actual full-player return, and the Library return. The
startup checks and activation blip are excluded from unlock comparisons.

| Metric | Full player | Library |
| --- | ---: | ---: |
| Captured interval | 12.445 s, including dismissal and next lock | 20.000 s |
| Will-enter-foreground to scene-active | 838 ms | 891 ms |
| Scene-active to first focus notification | 3,034 ms | 2,606 ms |
| Protected-data-available to first focus | 5,170 ms | 3,378 ms |
| Main-actor ticks in first six seconds after active | 308 | 174 |
| Median tick interval in that window | 11.10 ms | 31.61 ms |
| Largest tick interval in that window | 512 ms | 86 ms |

The player capture's first 7.276 seconds are the full player; its remaining
time includes closing it and beginning the Library lock test. Largest complete
tick intervals over the entire recorded returns were 512 ms and 532 ms; the
Library maximum occurred approximately 14.57 seconds after foreground entry,
outside the reported initial sluggish period. There were no one-second gaps.

In both returns, first focus notification precedes the delayed foreground cloud
retry/feed refresh. Cloud retry took approximately 0.02/0.01 ms; feed refresh
took approximately 4.6/133 ms elapsed. Inbox badge loads took approximately
189/172 ms elapsed; Queue badge loads approximately 66/31 ms. These async spans
include suspended time and are not direct blocking measurements. Neither
search-index operations nor audio-route/interruption events occurred during the
paired returns.

The recordings do not show a continuous four-to-six-second main-actor stall.
They support investigating the unlock/accessibility transition, while leaving
cooperative UI/accessibility work and OS behavior unresolved. No gesture or
spoken-output timestamp is recorded, so first focus is not a direct measurement
of VoiceOver speech latency or the instant the user unlocked. Requested a
same-sequence test in Apple's Settings as an independent system-app control.
No production fix is justified yet; the issue remains in progress.

## Settings control and candidate 282

Michael reports the same lock/unlock/flick sequence in Apple's Settings does
not pause VoiceOver. This narrows the symptom to Earshot or its interaction with
accessibility/audio services; it does not prove which component is responsible.

Code review found unconditional accessibility setters in every immediate and
delayed tab-badge suppression traversal, even when the values are already
correct. Candidate 282 guards those setter calls. It still visits every badge
and descendant, repairs newly created or reset UIKit views, preserves both
immediate and delayed repair passes, and leaves labels/values/traits/rotor/focus
requests untouched. Temporary probe events count actual property writes and
time each badge apply. This is a candidate for physical comparison, not a
trace-proven cause of the multi-second delay.

The existing badge regression is extended to count setter invocations on stable
fixture views across repeated immediate/delayed passes. The existing count-clear,
UIKit-rebuild and late-created-badge checks remain. Focused badge and speech
tests plus the Release device build are being run before phone installation.
The diagnostic also now prevents new captures after its persisted opt-in expires.

Focused simulator validation passed under Xcode 27.0 / iOS 26.5 on the existing
Earshot-ColdLaunch simulator: 13 executed, zero failures or skips. Includes the
extended `TabBarBadgeApplierTests`, four badge-format tests, and eight speech
tests. The badge test confirms stable immediate/delayed passes invoke no guarded
setters while clearing counts and repairing reset/late-created badges still work.
StoreKit suites were explicitly excluded per AGENTS.md. Existing unrelated
compiler warnings remain. No simulator result proves physical VoiceOver latency.

Release device build 282 succeeded and passed strict signature verification.
Direct installation, launch with recording enabled, installed-app query, and
actual report retrieval all succeeded. Version 1.2.5 (282), process 7776, VoiceOver
enabled. This is the first phone candidate with a behavior-preserving production
optimization; 280/281 were observational diagnostics. Awaiting the same paired
unlock test. No symptom improvement, root cause, CI pass, merge, or release is
claimed at this handoff.

## Physical acceptance and clean fix

After the requested paired player/Library unlock comparison on build 282,
Michael confirmed, “it's fixed.” This is acceptance of the reported unlock
responsiveness symptom in those checks. No numeric post-fix speech latency or
acceptance of unrelated behavior is inferred.

The retrieved build-282 report contains multiple player returns and a Library
return. Scene-active to first focus spans vary (player approximately 0.386,
6.796 and 1.363 seconds; Library 0.170 seconds). Without the physical gesture
timestamps, these are not interchangeable with perceived response latency;
do not select only the shortest sample as a measured speedup. Michael's direct
observation supplies acceptance. Stable badge passes recorded zero property
writes. The raw report remains in the local investigation data.

Recording on the installed diagnostic build was disabled by a successful launch
with `EARSHOT_UNLOCK_MEASURE=0`. Production probes and hooks were removed from
all unrelated files and the generated project; only the two conditional badge
setters and their regression coverage remain as product changes. The temporary
probe is archived as noncompiled text in `unlock-2026-10-27/` for reproducibility.
The clean rerun passed all 13 focused badge/speech tests, zero failures or skips,
and the clean Release device build (command-line build 283, not installed) passed.
Independent review of the scoped production/test diff found no actionable issues.
The dedicated reviewer agent's configured model was unavailable, so an independent
default reviewer performed the equivalent review using the archived review skill.
Acceptance is complete; StartTesting remains in testing only until the required
integration is finished. GitHub CI and merge are still pending.
