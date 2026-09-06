# Paused playback loses system controls

Michael reproduced Control Center changing to “Not Playing” after pausing
direct-installed Earshot 1.2.2 (255). In-app playback remains available. Chad
reported similar behavior on iOS 26.6.1 with AirPods and VoiceOver's magic tap;
Michael's paired iPhone reports iOS 27.0 (24A5430a). These are separate OS cases.

## Local diagnostic candidate

Based on local main `3df8304`, which includes the merged feedback and download
status work, but not the unmerged folder-run integration. Build 257 is a local
diagnostic label supplied through build overrides, not an App Store upload.
No player behavior, accessibility semantics, schema, or signing settings change.

`EARSHOT_PLAYBACK_DIAGNOSTICS` enables event-only logging. Without that explicit
build flag the logging helper is empty and the filesystem logger is excluded.
Snapshots include pause/resume, metadata publishing/clearing, unloading,
background persistence, interruption type/reason, route changes,
session activation failures, and incoming remote play/pause/toggle commands.
The scalar snapshot records transport state and output port type, but no podcast
titles, URLs, episode IDs, device names, or audio. Files are written off-main on
a serial queue into `Library/Caches/PlaybackDiagnostics/events.log`, rotating
at 256 KiB to one `previous.log`. This cache is device-local and best effort;
suspension can delay writes and iOS can purge it.

The metadata dictionary belongs to Earshot. A nonempty dictionary does not prove
that iOS selects Earshot globally. The app cannot log while suspended, and modern
iOS no longer reports the old `appWasSuspended` reason. Missing remote events alone
are not definitive proof of a system-routing failure. Correlate the timestamps
with Michael's observation and check both rotated logs and session IDs.

## Device acceptance procedure

1. Install over the existing app, without uninstalling or resetting data.
2. Launch normally, without a debugger or a keep-alive assertion.
3. Play a downloaded episode, then pause with the usual AirPods or VoiceOver
   control. Check that Control Center initially shows the episode.
4. Use the phone normally until Control Center says “Not Playing.” Note the
   approximate time, try remote Play once, and note which app responds.
5. Report before reopening Earshot if possible. Retrieve the log, then open
   Earshot and retrieve again to catch delayed interruption delivery.

Retrieve with `devicectl device copy from`, domain `appDataContainer`, identifier
`media.payown.earshot`, source `Library/Caches/PlaybackDiagnostics`. No debugger
or Instruments attachment is required. Verify retrieval before handing off.

Simulator checks cover metadata retention on explicit pause/background and
preventing automatic resume after an interruption while paused. They do not prove
cross-app system control ownership on a physical device.

## Validation

The diagnostic-enabled simulator run passed all 74 selected tests (seven audio
session tests and 67 advanced playback tests), including both new regression
checks. Result: `/tmp/earshot-paused-diagnostics-verified.xcresult`.
Reading the simulator cache confirmed timestamped diagnostic events are actually
written. The reserved CI simulator was not used. A compile-time mistake in the
first new test was corrected to assert the public presentation state; deprecated
interruption constants were removed before this final run.
