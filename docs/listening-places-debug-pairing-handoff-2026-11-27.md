# Listening Places Playback pairing handoff — November 27, 2026

## Runnable Mac rehearsal (Debug only)

This is a disposable simulator rehearsal, **not an installable 336 build**. The
Debug launch gate uses an in-memory Earshot library, a new temporary folder,
synthetic Apple-directory and RSS responses supplied by a local URL protocol,
and no iCloud account or real network feed. It cannot read Michael's library.
Use a free iOS simulator; do not reset or install over a real device.

From this isolated feature checkout, run this focused command on a free
disposable simulator, replacing the simulator ID and derived-data path with
paths dedicated to the rehearsal:

```sh
xcodebuild test -project Earshot.xcodeproj -scheme Earshot \
  -derivedDataPath /tmp/EarshotLPProvenanceDerived20261127 \
  -destination 'platform=iOS Simulator,id=23F12FE1-0D77-4B42-B766-ADD9F27A2153' \
  -parallel-testing-enabled NO \
  -only-testing:EarshotUITests/EarshotUITests/testDisposableListeningPlacesPlaybackUsesNativeSettingsAndDefersLoadedEpisode
```

The native Settings UI test opens **Listening
Places** and verifies these steps in order:

For hands-on inspection after the test installs the Debug app, launch that
same disposable simulator directly:

```sh
SIMCTL_CHILD_EARSHOT_LP_DISPOSABLE_SYNC=1 xcrun simctl launch \
  --terminate-running-process 23F12FE1-0D77-4B42-B766-ADD9F27A2153 \
  media.payown.earshot -uiTestScreenshotSeed \
  -screenshotScreen listeningPlacesPlayback
```

This exact launch succeeded and showed the native **Listening Places** Settings
screen with **Ready**, two public places and four blocked places. A disposable
simulator screenshot is at `/tmp/EarshotLPDebugPairingManual20261127.png`.

1. The disposable directory result follows an exact, anonymous public feed.
   **Share listening places** is on and the status reports two public places
   and four blocked sensitive or unverified places. The first Earshot-owned
   file contains the two public positions, 12 and 20 seconds.
2. **Sync synthetic peer place** applies the newer idle place (25 seconds),
   defers the loaded episode's rewind (still 12 seconds), and leaves both the
   Earshot-owned and peer files unchanged. Private and stale peer places stay
   at their original positions.
3. **Unload and apply deferred rewind** makes the loaded episode idle; the
   rewind then applies to 5 seconds. No echo is written to the owned file.
4. **Advance idle place and write back** records a later local 30-second
   event and changes only Earshot's owned file. The peer file stays byte for
   byte unchanged.
5. Turn off **Share listening places**. A separate disposable UI test injects
   an owned-file cleanup conflict, confirms the accessible stop failure, then
   repairs and retries. An on-disk service test holds a provider write,
   reopens a fresh store context and confirms stop intent survives restart.

The peer JSON is a synthetic QUILL-compatible file. Separate opted-in tests
consume pinned QUILL Cast source `64651e5884b779b7cf75e3c5cc4125b77a983e82`
fixtures; this Mac rehearsal does not claim that QUILL ran on Windows or that
a cloud provider synchronized the folder.

**Local validation:** the expanded native/receiver/stop-intent focused bundle
`/tmp/EarshotLPDebugPairingFocused2-20261127.xcresult` passed 5/5; the final
stale-public-peer UI bundle `/tmp/EarshotLPDebugPairingFinalUI20261127.xcresult`
passed 1/1. The final-source pinned QUILL fixture bundle
`/tmp/EarshotLPDebugPairingPinnedQuillFinal20261127.xcresult` passed 2/2.
The first
broad run (`/tmp/EarshotLPDebugPairingFull20261127.xcresult`) passed 2,965,
skipped 62, and failed two test cases. One was the writer inventory alarm for
the new reviewed Debug fixture assignments. The other test enumerated the
devices folder after adding a plain-text peer file and sometimes parsed that
peer as Earshot's JSON. Both test corrections passed 2/2 in
`/tmp/EarshotLPDebugPairingFailureFix20261127.xcresult`. The final broad
rerun (`/tmp/EarshotLPDebugPairingFullFinal20261127.xcresult`) passed 2,967,
skipped 62 and failed zero. This validates the release-disabled source; it
does not enable the receiver or establish physical/provider acceptance.

## Physical iPhone and Windows acceptance after an eligible internal build

Use a **new disposable test library** and a separate provider folder. Keep
the current beta and real library intact. Before turning sharing on, verify
that two distinct files can appear under `Listening Places/devices/`: one
owned by Earshot and one by QUILL. Each app must edit only its own file. If
the provider presents one combined/conflicted file, stop and report that
provider state rather than trying to repair a real library.

1. On iPhone, follow a public show through **Add Podcast** directory search.
   In **Settings > Listening Places**, choose the disposable folder, turn on
   **Share listening places**, then use **Write Now** after a disposable
   playback checkpoint. Confirm the owned file appears. A typed or private
   feed must stay out; never enter actual credentials for this test.
2. On a QUILL Cast build verified to include pinned revision
   `64651e5884b779b7cf75e3c5cc4125b77a983e82`, open **Podcasts > Carry
   My Place Between Machines**. Select **A plain file other apps can read**;
   leave **Also share the podcasts I follow** off for Playback-only testing.
   Confirm its **What happened** result identifies the shared folder/file and
   whether a place was read or written. A generic “Latest” desktop build is
   not evidence these controls exist.
3. Seek backward in QUILL to a **newer event time** than the iPhone's last
   checkpoint. With that episode idle on iPhone, Sync Now should apply the
   rewind. With it loaded, it should defer, then apply after unload. An older
   QUILL event must not overwrite newer iPhone progress. Check both files and
   repeat to confirm no ping-pong writes.
4. Make a later iPhone checkpoint and Sync Now. QUILL should receive that
   place while its own file remains owned by QUILL. With VoiceOver and NVDA,
   inspect the spoken result and focus, including deferral and any error.
5. Interrupt an Earshot write, turn sharing off, relaunch and inspect the
   pending stop status. Retry cleanup; only Earshot's file may be removed.
   Local playback/history and QUILL's file must survive. Record whether the
   provider actually delayed or conflicted, plus both apps' exact versions.

**Enable an internal 336 candidate only after** the release receiver and
subscription/folder scope are reviewed or kept disabled, credential and
device-only exclusions pass, exact-source iPhone/Watch regression and pinned
fixture gates are green, and file ownership/revocation survives provider
interruption. This Debug demonstration does not establish those release or
physical gates.
