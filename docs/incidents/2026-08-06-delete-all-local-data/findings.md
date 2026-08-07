# Delete all local data watchdog: independent diagnosis and measurements

Date: 2026-08-06 (US/Pacific)

Repository: `payown/earshot`

Diagnosis branch: `agent/reset-watchdog-diagnosis`

Baseline: `8ce477e27c887de81dfb4905700d47bdb0ab4604`

This document records Phases 1 through 5 of the independent preregistration,
measurement, comparison, and gated-fix run. Claims are labeled **Measured**,
**Derived**, **Inferred**, or **Judgment**. Raw command logs remain under
`evidence-review/` in the investigation worktree.

## Phase 1: setup, verification, and evidence staging

### 1.1 Worktree and toolchain

**Measured.** The worktree creation command returned:

```text
Preparing worktree (new branch 'agent/reset-watchdog-diagnosis')
HEAD is now at 8ce477e Merge pull request #802 from payown/agent/serialize-launch-announcements
```

The four untracked root files were copied into the worktree. They were not
moved, deleted, or committed from the main checkout. The exact current setup
output is:

```text
$ git worktree list
/Users/michaelbabcock/code/earshot                            8ce477e [main]
/Users/michaelbabcock/code/earshot-781-preparation            de522f5 [agent/781-migration-preparation]
/Users/michaelbabcock/code/earshot-appstore-assembly          17c4670 [docs/app-store-1.0-submission-assembly]
/Users/michaelbabcock/code/earshot-attributed-migration-disk  07bd923 [agent/attribute-migration-disk-usage]
/Users/michaelbabcock/code/earshot-backup-recovery            7b1e64e [agent/backup-recovery]
/Users/michaelbabcock/code/earshot-build-165-identity         148b888 [agent/build-165-identity]
/Users/michaelbabcock/code/earshot-build-165-release          806ea10 (detached HEAD)
/Users/michaelbabcock/code/earshot-device-fixture-validation  a289231 (detached HEAD)
/Users/michaelbabcock/code/earshot-interrupted-fresh-v10      75ace16 [agent/interrupted-fresh-v10]
/Users/michaelbabcock/code/earshot-launch-announcement-order  7d7459d [agent/serialize-launch-announcements]
/Users/michaelbabcock/code/earshot-migration-handoff          1239777 [agent/migration-state-handoff]
/Users/michaelbabcock/code/earshot-migration-shape-fixtures   83abec9 [agent/migration-shape-fixtures]
/Users/michaelbabcock/code/earshot-peak-control               806ea10 (detached HEAD)
/Users/michaelbabcock/code/earshot-perf-diagnosis             7dbac67 [agent/perf-diagnosis-2026-07-19]
/Users/michaelbabcock/code/earshot-perf-pass                  d6f5c81 [agent/perf-pass]
/Users/michaelbabcock/code/earshot-recovery-download-removal  8a5bb31 [agent/recovery-download-removal]
/Users/michaelbabcock/code/earshot-reset-diagnosis            fe03910 [agent/reset-watchdog-diagnosis]
/Users/michaelbabcock/code/earshot-v10-cold-launch            ae34315 [agent/v10-cold-launch]
/Users/michaelbabcock/code/earshot-v10-null-tombstone         7304fee [agent/v10-null-tombstone]
/Users/michaelbabcock/code/earshot-v5-production-migration    c261dce [agent/v5-production-migration]

$ git -C /Users/michaelbabcock/code/earshot status -sb
## main...origin/main
?? Earshot-2026-08-06-193440.ips
?? Earshot-2026-08-06-194039.ips
?? android/
?? earshot-migration-report.md
?? migration-state.md

$ git -C /Users/michaelbabcock/code/earshot-reset-diagnosis status -sb
## agent/reset-watchdog-diagnosis
 M EarshotTests/StoreMigrationV6toV8Tests.swift
 M docs/migration-state.md
?? Earshot-2026-08-06-193440.ips
?? Earshot-2026-08-06-194039.ips
?? docs/earshot-migration-report.md
?? docs/incidents/
?? earshot-migration-report.md
?? evidence-review/claude-invocation-attempt1.stderr
?? evidence-review/claude-prediction-attempt1.md
?? evidence-review/generate_opml.py
?? evidence-review/new-issue-delete-reset-watchdog.html
?? evidence-review/new-issue-delete-reset-watchdog.md
?? evidence-review/opml-disposable-path.txt
?? evidence-review/parse_ips.py
?? evidence-review/phase1-ips-parsed.txt
?? evidence-review/phase1-setup-output.txt
?? evidence-review/phase4-comparison.md
?? evidence-review/reconciliation-disposable-path.txt
?? evidence/
?? migration-state.md

$ xcodebuild -version
Xcode 26.6
Build version 17F113

$ swift --version
Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
```

### 1.2 Crash report parsing

**Measured.** This is the complete parsed metadata, termination array,
triggered-thread backtrace, and requested other-thread top-four output for both
reports:

```text
FILE|Earshot-2026-08-06-193440.ips
SHA256|1925c999f1d65f0232907a72c4c39ccbe8ebed1a2632817c05feda4ef75a8d71
BYTES|23322
bug_type|309
os_version|iPhone OS 27.0 (24A5390f)
releaseType|Beta
modelCode|iPhone18,2
build_version|165
slice_uuid|2742d5dd-245d-3fd4-bcc6-8d9d182eaf59
pid|19198
procLaunch|2026-08-06 15:40:28.3514 -0700
captureTime|2026-08-06 19:34:39.7354 -0700
uptimeSeconds|14051.3840
exception.type|EXC_CRASH
exception.signal|SIGKILL
exception.codes|0x0000000000000000, 0x0000000000000000
exception.rawCodes|[0,0]
termination.reasons|
[
  "<RBSTerminateContext| domain:10 code:0x8BADF00D explanation:scene-update watchdog transgression: app<media.payown.earshot(FEEDEEEE-DDDD-CCCC-BBBB-0000000001F5)>:19198 exhausted real (wall clock) time allowance of 10.00 seconds",
  "ProcessVisibility: Foreground",
  "ProcessState: Running",
  "WatchdogEvent: scene-update",
  "WatchdogVisibility: Background",
  "WatchdogCPUStatistics: (",
  "\"Elapsed total CPU time (seconds): 29.600 (user 23.300, system 6.300), 48% CPU\",",
  "\"Elapsed application CPU time (seconds): 10.235, 17% CPU\"",
  ")",
  "ThermalInfo: (",
  "\"Thermal Level:   0\",",
  "\"Thermal State:   nominal\"",
  ") reportType:CrashLog maxTerminationResistance:Interactive>"
]
TRIGGERED_THREAD|index=0|id=20014108
frame[0]|image=libswiftCore.dylib|offset=30940|symbol=bool swift::RefCounts<swift::RefCountBitsT<(swift::RefCountInlinedness)1>>::doDecrementSlow<(swift::PerformDeinit)1>(swift::RefCountBitsT<(swift::RefCountInlinedness)1>, unsigned int) +148
frame[1]|image=libswiftCore.dylib|offset=194976|symbol=Array.subscript.read +44
frame[2]|image=libswiftCore.dylib|offset=194976|symbol=Array.subscript.read +44
frame[3]|image=libswiftCore.dylib|offset=177988|symbol=protocol witness for Collection.subscript.read in conformance _ArrayBuffer<A> +40
frame[4]|image=libswiftCore.dylib|offset=1349376|symbol=MutableCollection._halfStablePartition(isSuffixElement:) +1284
frame[5]|image=libswiftCore.dylib|offset=1347544|symbol=RangeReplaceableCollection<>.removeAll(where:) +580
frame[6]|image=SwiftData|offset=533948|symbol=<unsymbolicated>
frame[7]|image=SwiftData|offset=518716|symbol=<unsymbolicated>
frame[8]|image=SwiftData|offset=517320|symbol=<unsymbolicated>
frame[9]|image=SwiftData|offset=510452|symbol=<unsymbolicated>
frame[10]|image=SwiftData|offset=520540|symbol=<unsymbolicated>
frame[11]|image=SwiftData|offset=542456|symbol=<unsymbolicated>
frame[12]|image=SwiftData|offset=540904|symbol=<unsymbolicated>
frame[13]|image=SwiftData|offset=508936|symbol=<unsymbolicated>
frame[14]|image=SwiftData|offset=541980|symbol=<unsymbolicated>
frame[15]|image=SwiftData|offset=510364|symbol=<unsymbolicated>
frame[16]|image=SwiftData|offset=534924|symbol=<unsymbolicated>
frame[17]|image=SwiftData|offset=535448|symbol=<unsymbolicated>
frame[18]|image=SwiftData|offset=530976|symbol=<unsymbolicated>
frame[19]|image=SwiftData|offset=536128|symbol=<unsymbolicated>
frame[20]|image=SwiftData|offset=537892|symbol=<unsymbolicated>
frame[21]|image=SwiftData|offset=403576|symbol=<unsymbolicated>
frame[22]|image=SwiftData|offset=57104|symbol=<unsymbolicated>
frame[23]|image=SwiftData|offset=439032|symbol=<unsymbolicated>
frame[24]|image=Earshot|offset=3628992|symbol=specialized static SettingsReset.deleteAllLocalData(context:) +272
frame[25]|image=Earshot|offset=382500|symbol=DataSettingsView.factoryReset() +280
frame[26]|image=Earshot|offset=382200|symbol=closure #1 in closure #4 in DataSettingsView.body.getter +136
frame[27]|image=SwiftUI|offset=3902500|symbol=<deduplicated_symbol> +32
frame[28]|image=SwiftUI|offset=3893420|symbol=specialized static MainActor.assumeIsolated<A>(_:file:line:) +140
frame[29]|image=SwiftUI|offset=3902308|symbol=ButtonAction.callAsFunction() +384
frame[30]|image=SwiftUI|offset=3901904|symbol=<deduplicated_symbol> +88
frame[31]|image=SwiftUI|offset=15315404|symbol=UIKitDialogBridge.performDialogAction(_:) +640
frame[32]|image=SwiftUI|offset=9484576|symbol=closure #1 in PlatformItemList.Item.alertAction(delegate:) +96
frame[33]|image=SwiftUI|offset=6149468|symbol=<deduplicated_symbol> +52
frame[34]|image=UIKitCore|offset=9403228|symbol=-[UIAlertController _invokeHandlersForAction:] +88
frame[35]|image=UIKitCore|offset=9405348|symbol=__103-[UIAlertController _dismissAnimated:triggeringAction:triggeredByPopoverDimmingView:dismissCompletion:]_block_invoke_2 +36
frame[36]|image=UIKitCore|offset=1717352|symbol=-[UIPresentationController transitionDidFinish:] +860
frame[37]|image=UIKitCore|offset=11828592|symbol=__77-[UIPresentationController runTransitionForCurrentStateAnimated:handoffData:]_block_invoke.165 +344
frame[38]|image=UIKitCore|offset=1549248|symbol=-[_UIViewControllerTransitionContext completeTransition:] +192
frame[39]|image=UIKitCore|offset=760064|symbol=__UIVIEW_IS_EXECUTING_ANIMATION_COMPLETION_BLOCK__ +36
frame[40]|image=UIKitCore|offset=194588|symbol=-[UIViewAnimationBlockDelegate _didEndBlockAnimation:finished:context:] +628
frame[41]|image=UIKitCore|offset=194908|symbol=-[UIViewAnimationState sendDelegateAnimationDidStop:finished:] +256
frame[42]|image=UIKitCore|offset=758668|symbol=-[UIViewAnimationState animationDidStop:finished:] +192
frame[43]|image=UIKit|offset=17520|symbol=-[UIViewAnimationStateAccessibility animationDidStop:finished:] +220
frame[44]|image=UIKitCore|offset=758780|symbol=-[UIViewAnimationState animationDidStop:finished:] +304
frame[45]|image=UIKit|offset=17520|symbol=-[UIViewAnimationStateAccessibility animationDidStop:finished:] +220
frame[46]|image=QuartzCore|offset=1169044|symbol=run_animation_callbacks(void*) +196
frame[47]|image=libdispatch.dylib|offset=114644|symbol=_dispatch_client_callout +16
frame[48]|image=libdispatch.dylib|offset=70512|symbol=_dispatch_main_queue_drain +800
frame[49]|image=libdispatch.dylib|offset=69696|symbol=_dispatch_main_queue_callback_4CF +44
frame[50]|image=CoreFoundation|offset=300616|symbol=__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__ +16
frame[51]|image=CoreFoundation|offset=239512|symbol=__CFRunLoopRun +1704
frame[52]|image=CoreFoundation|offset=243456|symbol=_CFRunLoopRunSpecificWithOptions +344
frame[53]|image=GraphicsServices|offset=3876|symbol=GSEventRunModal +120
frame[54]|image=UIKitCore|offset=755808|symbol=UIApplicationMain +336
frame[55]|image=SwiftUI|offset=297184|symbol=closure #1 in KitRendererCommon(_:) +168
frame[56]|image=SwiftUI|offset=270440|symbol=runApp<A>(_:) +136
frame[57]|image=SwiftUI|offset=270120|symbol=static App.main() +172
frame[58]|image=Earshot|offset=739552|symbol=main +64
frame[59]|image=dyld|offset=22064|symbol=start +6616
OTHER_THREAD|index=1|id=20213896|name=com.apple.UIKit.inProcessAnimationManager|queue=None
top[0]|image=libsystem_kernel.dylib|offset=3152|symbol=semaphore_wait_trap +8
top[1]|image=libdispatch.dylib|offset=14444|symbol=_dispatch_sema4_wait +28
top[2]|image=libdispatch.dylib|offset=16208|symbol=_dispatch_semaphore_wait_slow +156
top[3]|image=AnimationKit|offset=234748|symbol=<unsymbolicated>
OTHER_THREAD|index=2|id=20214440|name=None|queue=None
OTHER_THREAD|index=3|id=20214644|name=None|queue=None
OTHER_THREAD|index=4|id=20214645|name=None|queue=None
OTHER_THREAD|index=5|id=20214680|name=None|queue=None
OTHER_THREAD|index=6|id=20215405|name=AudioSession - RootQueue|queue=None
top[0]|image=libsystem_kernel.dylib|offset=3176|symbol=semaphore_timedwait_trap +8
top[1]|image=libdispatch.dylib|offset=14584|symbol=_dispatch_sema4_timedwait +88
top[2]|image=libdispatch.dylib|offset=16116|symbol=_dispatch_semaphore_wait_slow +64
top[3]|image=libdispatch.dylib|offset=83640|symbol=_dispatch_worker_thread +272
END_FILE
FILE|Earshot-2026-08-06-194039.ips
SHA256|061f160c168b0f6b4d05074e63cac90d0827ba2f48ab00d8f18c00a1621fd112
BYTES|21674
bug_type|309
os_version|iPhone OS 27.0 (24A5390f)
releaseType|Beta
modelCode|iPhone18,2
build_version|165
slice_uuid|2742d5dd-245d-3fd4-bcc6-8d9d182eaf59
pid|20911
procLaunch|2026-08-06 19:34:51.0546 -0700
captureTime|2026-08-06 19:40:38.9931 -0700
uptimeSeconds|347.9385
exception.type|EXC_CRASH
exception.signal|SIGKILL
exception.codes|0x0000000000000000, 0x0000000000000000
exception.rawCodes|[0,0]
termination.reasons|
[
  "<RBSTerminateContext| domain:10 code:0x8BADF00D explanation:scene-update watchdog transgression: app<media.payown.earshot(FEEDEEEE-DDDD-CCCC-BBBB-0000000001F5)>:20911 exhausted real (wall clock) time allowance of 10.00 seconds",
  "ProcessVisibility: Foreground",
  "ProcessState: Running",
  "WatchdogEvent: scene-update",
  "WatchdogVisibility: Background",
  "WatchdogCPUStatistics: (",
  "\"Elapsed total CPU time (seconds): 22.290 (user 18.600, system 3.690), 36% CPU\",",
  "\"Elapsed application CPU time (seconds): 10.434, 17% CPU\"",
  ")",
  "ThermalInfo: (",
  "\"Thermal Level:   0\",",
  "\"Thermal State:   nominal\"",
  ") reportType:CrashLog maxTerminationResistance:Interactive>"
]
TRIGGERED_THREAD|index=0|id=20215821
frame[0]|image=libswiftCore.dylib|offset=30392|symbol=swift_release +4
frame[1]|image=SwiftData|offset=337788|symbol=<unsymbolicated>
frame[2]|image=SwiftData|offset=432956|symbol=<unsymbolicated>
frame[3]|image=SwiftData|offset=434108|symbol=<unsymbolicated>
frame[4]|image=SwiftData|offset=433396|symbol=<unsymbolicated>
frame[5]|image=SwiftData|offset=334224|symbol=<unsymbolicated>
frame[6]|image=SwiftData|offset=485892|symbol=<unsymbolicated>
frame[7]|image=SwiftData|offset=533712|symbol=<unsymbolicated>
frame[8]|image=SwiftData|offset=518716|symbol=<unsymbolicated>
frame[9]|image=SwiftData|offset=517320|symbol=<unsymbolicated>
frame[10]|image=SwiftData|offset=510452|symbol=<unsymbolicated>
frame[11]|image=SwiftData|offset=520540|symbol=<unsymbolicated>
frame[12]|image=SwiftData|offset=542456|symbol=<unsymbolicated>
frame[13]|image=SwiftData|offset=540904|symbol=<unsymbolicated>
frame[14]|image=SwiftData|offset=508936|symbol=<unsymbolicated>
frame[15]|image=SwiftData|offset=541980|symbol=<unsymbolicated>
frame[16]|image=SwiftData|offset=510364|symbol=<unsymbolicated>
frame[17]|image=SwiftData|offset=534924|symbol=<unsymbolicated>
frame[18]|image=SwiftData|offset=535448|symbol=<unsymbolicated>
frame[19]|image=SwiftData|offset=530976|symbol=<unsymbolicated>
frame[20]|image=SwiftData|offset=536128|symbol=<unsymbolicated>
frame[21]|image=SwiftData|offset=537892|symbol=<unsymbolicated>
frame[22]|image=SwiftData|offset=403576|symbol=<unsymbolicated>
frame[23]|image=SwiftData|offset=57104|symbol=<unsymbolicated>
frame[24]|image=SwiftData|offset=439032|symbol=<unsymbolicated>
frame[25]|image=Earshot|offset=3628992|symbol=specialized static SettingsReset.deleteAllLocalData(context:) +272
frame[26]|image=Earshot|offset=382500|symbol=DataSettingsView.factoryReset() +280
frame[27]|image=Earshot|offset=382200|symbol=closure #1 in closure #4 in DataSettingsView.body.getter +136
frame[28]|image=SwiftUI|offset=3902500|symbol=<deduplicated_symbol> +32
frame[29]|image=SwiftUI|offset=3893420|symbol=specialized static MainActor.assumeIsolated<A>(_:file:line:) +140
frame[30]|image=SwiftUI|offset=3902308|symbol=ButtonAction.callAsFunction() +384
frame[31]|image=SwiftUI|offset=3901904|symbol=<deduplicated_symbol> +88
frame[32]|image=SwiftUI|offset=15315404|symbol=UIKitDialogBridge.performDialogAction(_:) +640
frame[33]|image=SwiftUI|offset=9484576|symbol=closure #1 in PlatformItemList.Item.alertAction(delegate:) +96
frame[34]|image=SwiftUI|offset=6149468|symbol=<deduplicated_symbol> +52
frame[35]|image=UIKitCore|offset=9403228|symbol=-[UIAlertController _invokeHandlersForAction:] +88
frame[36]|image=UIKitCore|offset=9405348|symbol=__103-[UIAlertController _dismissAnimated:triggeringAction:triggeredByPopoverDimmingView:dismissCompletion:]_block_invoke_2 +36
frame[37]|image=UIKitCore|offset=1717352|symbol=-[UIPresentationController transitionDidFinish:] +860
frame[38]|image=UIKitCore|offset=11828592|symbol=__77-[UIPresentationController runTransitionForCurrentStateAnimated:handoffData:]_block_invoke.165 +344
frame[39]|image=UIKitCore|offset=1549248|symbol=-[_UIViewControllerTransitionContext completeTransition:] +192
frame[40]|image=UIKitCore|offset=760064|symbol=__UIVIEW_IS_EXECUTING_ANIMATION_COMPLETION_BLOCK__ +36
frame[41]|image=UIKitCore|offset=194588|symbol=-[UIViewAnimationBlockDelegate _didEndBlockAnimation:finished:context:] +628
frame[42]|image=UIKitCore|offset=194908|symbol=-[UIViewAnimationState sendDelegateAnimationDidStop:finished:] +256
frame[43]|image=UIKitCore|offset=758668|symbol=-[UIViewAnimationState animationDidStop:finished:] +192
frame[44]|image=UIKit|offset=17520|symbol=-[UIViewAnimationStateAccessibility animationDidStop:finished:] +220
frame[45]|image=UIKitCore|offset=758780|symbol=-[UIViewAnimationState animationDidStop:finished:] +304
frame[46]|image=UIKit|offset=17520|symbol=-[UIViewAnimationStateAccessibility animationDidStop:finished:] +220
frame[47]|image=QuartzCore|offset=1169044|symbol=run_animation_callbacks(void*) +196
frame[48]|image=libdispatch.dylib|offset=114644|symbol=_dispatch_client_callout +16
frame[49]|image=libdispatch.dylib|offset=70512|symbol=_dispatch_main_queue_drain +800
frame[50]|image=libdispatch.dylib|offset=69696|symbol=_dispatch_main_queue_callback_4CF +44
frame[51]|image=CoreFoundation|offset=300616|symbol=__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__ +16
frame[52]|image=CoreFoundation|offset=239512|symbol=__CFRunLoopRun +1704
frame[53]|image=CoreFoundation|offset=243456|symbol=_CFRunLoopRunSpecificWithOptions +344
frame[54]|image=GraphicsServices|offset=3876|symbol=GSEventRunModal +120
frame[55]|image=UIKitCore|offset=755808|symbol=UIApplicationMain +336
frame[56]|image=SwiftUI|offset=297184|symbol=closure #1 in KitRendererCommon(_:) +168
frame[57]|image=SwiftUI|offset=270440|symbol=runApp<A>(_:) +136
frame[58]|image=SwiftUI|offset=270120|symbol=static App.main() +172
frame[59]|image=Earshot|offset=739552|symbol=main +64
frame[60]|image=dyld|offset=22064|symbol=start +6616
OTHER_THREAD|index=1|id=20220667|name=com.apple.UIKit.inProcessAnimationManager|queue=None
top[0]|image=libsystem_kernel.dylib|offset=3152|symbol=semaphore_wait_trap +8
top[1]|image=libdispatch.dylib|offset=14444|symbol=_dispatch_sema4_wait +28
top[2]|image=libdispatch.dylib|offset=16208|symbol=_dispatch_semaphore_wait_slow +156
top[3]|image=AnimationKit|offset=234748|symbol=<unsymbolicated>
OTHER_THREAD|index=2|id=20222013|name=None|queue=None
OTHER_THREAD|index=3|id=20222021|name=None|queue=None
OTHER_THREAD|index=4|id=20222163|name=None|queue=None
OTHER_THREAD|index=5|id=20222258|name=None|queue=None
END_FILE
```

Report 1 has 18 SwiftData frames after
`RangeReplaceableCollection.removeAll(where:)`; report 2 has 24 SwiftData
frames after `swift_release`. Both converge at Earshot image offset 3,628,992.
No captured non-main thread has a SQLite, Core Data, or filesystem-I/O frame.

### 1.3 CPU saturation arithmetic

**Derived.** Exact arithmetic:

```text
report1_uptime_seconds=(19:34:39.7354-15:40:28.3514)=14051.3840
report1_app_core_equivalents=10.235/10.00=1.0235
report1_conditional_6core_percent=(10.235/10.00)/6*100=17.0583
report1_app_implied_window_if_6cores=10.235/(0.17*6)=10.0343
report1_total_implied_window_if_6cores=29.600/(0.48*6)=10.2778
report2_uptime_seconds=(19:40:38.9931-19:34:51.0546)=347.9385
report2_app_core_equivalents=10.434/10.00=1.0434
report2_conditional_6core_percent=(10.434/10.00)/6*100=17.3900
report2_app_implied_window_if_6cores=10.434/(0.17*6)=10.2294
report2_total_implied_window_if_6cores=22.290/(0.36*6)=10.3194
```

**Derived, conditional.** If iPhone18,2 has six CPU cores, the report
percentages are internally consistent with approximately one core saturated for
the 10-second scene-update allowance. Local Xcode files contained no
`iPhone18,2` core-count evidence, so the six-core premise is not verified and is
an Unknown. The crash samples themselves show Swift/SwiftData compute, not I/O.

### 1.4 Exact reset path

Source citations below refer to the worktree source at baseline main:

- `Earshot/Features/Settings/Domain/SettingsReset.swift:6-7`: the function is
  `@MainActor` and synchronous.
- `SettingsReset.swift:14`: synchronous player-shutdown notification.
- `SettingsReset.swift:15-25`: deletion order is Podcast, Episode, QueueItem,
  ListeningSession, Bookmark, PodcastFolder, FolderMembership,
  EpisodeFolderMembership, RecentlyExpired, QuickActionConfig, AppSetting.
- `SettingsReset.swift:26-30`: `context.save()` is attempted once. Failure is
  logged as `Factory reset save failed: …`, then execution continues to
  filesystem deletion; failure is not returned to the caller.
- `SettingsReset.swift:35-38`: each deletion fetches the complete model table
  with `FetchDescriptor<T>()`, then calls `context.delete(object)` per object.
- `SettingsReset.swift:41-46`: the download path is the current process
  sandbox’s `.documentDirectory/Downloads`; `try? removeItem` suppresses every
  resolution/removal error.
- `SettingsReset.swift:52-55` and
  `Earshot/Data/Services/ArtworkCache.swift:83-88,172-176`: the live URL cache is
  cleared, then the current process sandbox’s `.cachesDirectory/artwork` is
  removed with errors suppressed.
- `Earshot/Features/Settings/Presentation/DataSettingsView.swift:63-70`: the
  confirmation action calls `factoryReset()` synchronously.
- `DataSettingsView.swift:116-123`: the caller waits for reset to return, then
  schedules the success announcement 0.5 seconds later.

Existing reset-flow user-facing strings, verbatim:

```text
Data
Delete all local data
Delete all local data?
Delete everything
Cancel
Removes every podcast, episode, download, and setting on this device. This can't be undone.
All local data deleted. Podcasts you follow and downloads removed.
```

### 1.5 Safety gate

**Measured determination.** The filesystem paths are process-global sandbox
Documents and Caches paths and cannot be redirected to a test-owned root.
Accordingly, every Phase 3 timing skipped the notification post, Downloads
removal, live `ArtworkCache.clear()`, and artwork-directory removal. Candidates
(a), (b), and (c) timed only SwiftData deletion plus save. Candidate (d) removed
only disposable store files and is explicitly non-equivalent. No real
Documents or Caches directory was touched.

### 1.6 Independent-review evidence directory

**Measured.** Before independent review, `evidence/` contained only raw copied
evidence and source paths:

```text
21299 evidence/earshot-migration-report.md
21674 evidence/Earshot-2026-08-06-194039.ips
23322 evidence/Earshot-2026-08-06-193440.ips
29600 evidence/migration-state.md
483 evidence/source-paths.txt
```

It contained no analysis, conclusions, or timings.

## Phase 2: independent preregistration before measurement

### 2.1 Claude Code invocation capability

**Measured.** `claude --version` returned:

```text
2.1.206 (Claude Code)
```

`claude --help` documented `-p, --print` for non-interactive mode,
`--allowedTools, --allowed-tools` for tool permissions, `--permission-mode`
including `dontAsk`, and `--output-format` values `text`, `json`, and
`stream-json`. The available timeout executable was `/opt/homebrew/bin/timeout`.

The first successful Claude execution produced output, but its wrapper then
failed because zsh reserves `status`:

```text
zsh:1: read-only variable: status
```

Its output was preserved as
`evidence-review/claude-prediction-attempt1.md`. The one permitted retry used:

```text
{ /usr/bin/time -p /opt/homebrew/bin/timeout 2700 claude --safe-mode --print --permission-mode dontAsk --allowedTools Read --output-format text --no-session-persistence < evidence-review/claude-prompt.txt > evidence-review/claude-prediction.md; } 2> evidence-review/claude-invocation.stderr; exit_code=$?; printf 'exit_code=%d\n' "$exit_code"; cat evidence-review/claude-invocation.stderr; exit "$exit_code"
```

Exact wrapper result:

```text
exit_code=0
real 498.71
user 2.15
sys 0.75
```

### 2.2–2.3 Complete Claude Code captured output

The following is the complete, unedited content of
`evidence-review/claude-prediction.md`:

---

# Independent Diagnostic Review — Delete-all-local-data watchdog kill

## A. CPU-bound or I/O-blocked? (derived)

Both crash reports give two independent numbers per incident:

**Report 1** (pid 19198): total CPU 29.600s at 48% CPU; application (main-thread) CPU 10.235s at 17% CPU.
**Report 2** (pid 20911): total CPU 22.290s at 36% CPU; application CPU 10.434s at 17% CPU.

If "X% CPU" means "X seconds of CPU consumed per second of wall-clock accounting window," the window length is recoverable by division:

- Report 1: total → 29.600/0.48 = 61.67s; app → 10.235/0.17 = 60.21s
- Report 2: total → 22.290/0.36 = 61.92s; app → 10.434/0.17 = 61.38s

All four independent divisions converge on **≈60–62 seconds**, so the statistics are reporting over a rolling ~60s window, not the fatal 10.00s scene-update allowance itself. This is the only self-consistent reading: if the window were the literal 10.00s allowance, 10.235s/10.434s of single-thread CPU would exceed the wall-clock time available to a single thread (>100%), which is impossible — ruling out the alternative interpretation.

Given a ~60s window, the main thread was only actually running **≈17% of the time (~10.2–10.4s of ~60s)** in both incidents. A tight, non-blocking, single-threaded compute loop over tens of thousands of objects would show close to 90–100% duty cycle. 17% means the main thread was off-CPU roughly 5x more than it was on-CPU — consistent with it repeatedly blocking (most plausibly on synchronous SQLite reads/writes/fsyncs as SwiftData faults relationships and stages the delete) between short compute bursts, rather than spinning purely in memory.

This is corroborated, weakly, by the "system" component of total CPU (6.300s of 29.600s in report 1, 21%) — real kernel time attributable to the app, consistent with syscall-driven I/O rather than pure user-space compute. It's also consistent with the two backtraces themselves: both samples caught the thread mid-compute inside Swift/ARC machinery (never inside a read()/write()/fsync() frame) — which is expected precisely because compute bursts, not the blocking calls between them, are the more probable place to land a stack sample, so this doesn't contradict the duty-cycle finding.

**Conclusion: blocked far more than it is CPU-bound — the main thread was executing only ~17% of the accounting window.** (derived from the CPU-statistics arithmetic; the specific attribution to I/O rather than lock contention or scheduler preemption is inferred, since the crash report can't directly show what the thread was waiting on when off-CPU.)

## B. Exact mechanism (derived from source, some inference for closed-source SwiftData internals)

`DataSettingsView.factoryReset()` (DataSettingsView.swift:116-123) calls `SettingsReset.deleteAllLocalData(context:)` **synchronously**, on `@MainActor` (SettingsReset.swift:6-7), directly from the destructive alert's action handler (DataSettingsView.swift:67, inside `MainActor.assumeIsolated`, matching the crash trace's `ButtonAction.callAsFunction()` → `MainActor.assumeIsolated` frames).

The first line of real work is `deleteAll(Podcast.self, context)` (SettingsReset.swift:15). `deleteAll` fetches all `Podcast` rows (only 10 — cheap) and calls `context.delete(object)` on each (SettingsReset.swift:36-38). `Podcast.episodes` is `@Relationship(deleteRule: .cascade, inverse: \Episode.podcast)` (Podcast.swift:51-52), so deleting a Podcast forces SwiftData to fault in and mark for deletion **every one of its Episodes** — ~53,864 across 10 podcasts. Each faulted Episode itself carries three more `.cascade` relationships (`queueItem`, `bookmarks`, `recentlyExpired` — Episode.swift:70-77) and two `.nullify` relationships (`listeningSessions`, `folderMemberships` — Episode.swift:78-81) that must also be resolved per episode.

Then, on line 16, `deleteAll(Episode.self, context)` runs **again** — an independent `FetchDescriptor<Episode>()` that re-fetches and re-issues `context.delete` for essentially the same ~53,864 rows already reached via cascade on line 15. None of this is preceded by `context.save()` (that only happens at line 26-27), so the entire multi-tens-of-thousands-of-object mutation set accumulates in the `ModelContext`'s in-memory pending-change bookkeeping before anything is committed.

The two crash backtraces show exactly this kind of Swift-side bookkeeping caught mid-flight: Report 1 is inside `RangeReplaceableCollection.removeAll(where:)` / `MutableCollection._halfStablePartition` (libswiftCore, imageIndex 2) — an O(n)-per-call array scan-and-compact, called from inside SwiftData (imageIndex 3) — consistent with SwiftData repeatedly filtering a deleted/registered-object array on every individual delete. Report 2 is inside a plain `swift_release` — consistent with ARC teardown of a large retained array/object graph during the same cascade machinery. Both land inside SwiftData's Swift-level object-graph code (imageIndex 3), never in a raw store/file call, immediately under `SettingsReset.deleteAllLocalData(context:)` (SettingsReset.swift:15 / :36-38) → `DataSettingsView.factoryReset()` (DataSettingsView.swift:117) in both traces.

## C. Pre-registered prediction: complexity and numbers (inferred — commit, no hedging)

**Complexity model:** O(N²) in episode count N, largely independent of P. The dominant term is the P-independent redundant full-table pass at SettingsReset.swift:16 (`deleteAll(Episode.self, context)`), which always re-touches all N episodes regardless of how many podcasts they belong to; the cascade-from-Podcast phase (SettingsReset.swift:15) contributes an additional term that scales as N²/P (P separate quadratic scans, each over N/P episodes). Model: **T(N,P) = k·N² + k·N²/P = k·N²·(1 + 1/P)**, using equal constants for the two terms as the simplest defensible assumption.

Committed numeric predictions:

- **t(2N)/t(N) at fixed P=1:** doubling N quadruples cost → **4.0**
- **1 podcast × 40,000 episodes vs. 4 podcasts × 10,000 episodes** (same total N=40,000): factor(P=1)=2, factor(P=4)=1.25 → ratio **≈1.6** (1-podcast case ~1.6x slower)
- **1 podcast × 40,000 vs. 16 podcasts × 2,500** (same total N): factor(P=1)=2, factor(P=16)=1.0625 → ratio **≈1.9** (1-podcast case ~1.9x slower)
- **Point estimate for 10 podcasts / 53,864 episodes, current implementation, to completion, modern Mac simulator: 60 seconds.** Range I'd be surprised to fall outside: **15–240 seconds.**

Reasoning behind the point estimate: the measured V5 migration (a genuinely different, near-linear code path — lightweight schema migration off the main actor, PR #785) moved 53,946 episodes in 2.377s in the simulator (migration-state.md, "Real V5 result"). That's real evidence SwiftData *can* be fast at N-scale operations when it isn't doing per-object fetch/fault/cascade/ARC churn. The delete path does something structurally worse (double materialization of the Episode table, cascade-triggered relationship faulting, and — per the crash traces — repeated array partition/ARC teardown), so its cost per episode should be well above the 44µs/episode the migration achieves, but is still bounded by plausible per-element bookkeeping costs (tens of nanoseconds per array-scan comparison) at N≈54,000. Chaining that constant through the model above and discounting for a simulator/Mac speed advantage over the on-device A-series chip that couldn't finish even the first ~10s CPU-time slice lands around a minute, with wide uncertainty because no timing data for this exact path exists at all.

## D. Pre-registered prediction: off-main-actor acceptability for VoiceOver (inferred)

**No.**

Moving the work off the main actor with *no other change* fixes the crash (no watchdog kill, no data loss risk from an interrupted mid-cascade state) but does nothing about user experience: a blind VoiceOver user taps "Delete everything" and, per my C estimate, hears **total silence for on the order of a minute, plausibly 15s–4min**, with no spinner-equivalent because VoiceOver has no channel besides speech. There is direct behavioral evidence this is already a bad experience even at the ~10s mark: the second crash report is described as "a second delete attempt, not a launch crash" (migration-state.md) — i.e., after the first attempt appeared to hang, the user (or tester) retried, the classic "did anything happen?" response to unexplained silence during a destructive action.

**Duration threshold at which this flips to acceptable: ~3 seconds of unannounced silence.** Below that, a brief pause after a destructive confirmation reads as normal system latency even without a spinner. Above it — and especially past 5-10s — silence during an action explicitly framed as irreversible ("Delete everything," "This can't be undone" — DataSettingsView.swift:70) starts to read as failure, and a screen-reader user has no way to distinguish "still working" from "crashed" without an interim announcement or heartbeat (the existing preparation-screen pattern from #786 already establishes this need for the migration path). My C estimate is 5–80x past this threshold, so background-only is not sufficient regardless of where exactly the threshold sits within a few seconds.

## E. Remedy ranking, fastest first (derived from source + inferred SwiftData batch-delete behavior)

1. **(d) Tear down the ModelContainer, remove store files** — fastest by a wide margin. No per-row Swift object materialization at all; deleting a handful of SQLite files (+ -wal/-shm) is proportional to file count, not row count, effectively O(1) in N. **Scope change:** deletes everything in the container unconditionally, including things SwiftData-level deletion wouldn't necessarily touch identically — and per EarshotSchema.swift, V10 is a **split store** (`mirroredModels` + `localModels` in separate files), so both stores (and any completion markers) must be removed together or a future launch could see an inconsistent split-store state. It also bypasses the `NotificationCenter.default.post(name: .earshotWillDeleteEpisodes...)` observer pattern entirely (SettingsReset.swift:14) — harmless here since that notification already fires unconditionally before any deletion mechanism runs, but it's a real scope/architecture difference (no per-object granularity, ever). It also invalidates the `@Environment(\.modelContext)` (DataSettingsView.swift:9) that live views hold, requiring the app to swap in a fresh context/container app-wide.

2. **(c) SwiftData batch delete by model type in dependency order** — next fastest. `context.delete(model:where:)` executes as a store-level (SQL) operation without fetching/faulting Swift objects per row, avoiding the ARC/array-partition cost visible in both crash traces. **Scope change:** same end state (all 11 tables empty) as the current code, but you must sequence model types yourself (children before parents: QueueItem/Bookmark/RecentlyExpired/ListeningSession/FolderMembership/EpisodeFolderMembership before Episode, before Podcast/PodcastFolder) since batch delete may not honor `.cascade` the same way object-graph deletion does — this needs verification, since getting the order wrong risks orphaned rows or FK violations rather than just being slow.

3. **(b) Delete Episodes explicitly before Podcasts** — meaningfully faster than (a) but still slow. Swapping order so `deleteAll(Episode.self, context)` runs before `deleteAll(Podcast.self, context)` means when Podcast is finally deleted, its `episodes` cascade relationship is already empty, eliminating the double fetch/fault of the same ~53,864 rows. **Scope change:** identical end state, same object-by-object `context.delete` mechanism (SettingsReset.swift:35-39 unchanged), so if the O(n)-per-call bookkeeping cost is driven by the context's total pending-change set (not specifically by cascade-vs-explicit), this removes roughly half the redundant work but doesn't change the underlying quadratic shape — still very likely watchdog-killed at this N.

4. **(a) Current implementation, podcasts deleted first** — slowest. Same total object count as (b), but does it via the most expensive path: cascade-fault of ~53,864 Episodes off Podcast deletion (SettingsReset.swift:15), *then* redundantly re-fetches and re-deletes essentially the same set explicitly (SettingsReset.swift:16), doubling the Episode-table materialization cost.

## F. Independent critique of the two project documents

**1. "24 SwiftData frames and RangeReplaceableCollection.removeAll(where:)" (earshot-migration-report.md, OPEN DEFECT section; identical text in migration-state.md, OPEN DEFECT section) is a composite that matches neither crash report individually.** Counting `imageIndex:3` (SwiftData) frames directly: Report 1 (193440) has **18** SwiftData frames, and its preceding libswiftCore frames *do* include `_halfStablePartition`/`removeAll(where:)`. Report 2 (194039) has **24** SwiftData frames, but its preceding libswiftCore frame is a plain `swift_release` — no partition or `removeAll` anywhere in that trace. The docs' single sentence attributes "24 frames" + "removeAll(where:)" as if it describes one unified signature, but that combination is present in neither report as stated — 24 frames belongs to the report without removeAll, and removeAll belongs to the report with 18 frames. This is a factual, independently verifiable inaccuracy, and it matters diagnostically: the two incidents are dying at two genuinely different points in SwiftData's internals (bulk array compaction vs. ARC teardown), which is worth knowing precisely rather than blurring into one description, since it bears on where the O(n)-per-touch cost is actually coming from.

**2. Unreconciled episode-count discrepancy.** The OPEN DEFECT section (both docs) states the delete "runs on the main thread over roughly 53,864 episodes." Elsewhere in the *same documents*, the presumably-same 10-podcast production store is repeatedly and precisely measured at **53,946 episodes** (e.g., migration-state.md "Preserved fixtures → Public build-155 V5 production shape": "10 podcasts and 53,946 episodes"; earshot-migration-report.md "Real build-155 V5 fixture": "10 subscriptions and 53,946 episodes"). That's an 82-episode gap the documents never explain. There's a plausible reconciling fact sitting elsewhere in the same document — "The production V5 store contained 86 duplicate episode GUID pairs... Per-podcast identity repair removed the duplicates afterward" — but 53,946 − 86 = 53,860, still 4 off from 53,864, and neither document draws this connection or otherwise accounts for the gap. Given how precisely everything else in these documents is measured and cited (down to individual 4,096-byte blocks), an unexplained, uncited "roughly 53,864" sitting next to a repeatedly-verified exact 53,946 is worth flagging as stale/imprecise.

**3. Omission, not an error: the docs don't connect this defect to the codebase's own established fix pattern.** PR #785 ("Run store migration off the main actor") and #786 ("Move store preparation off the launch watchdog path") are presented as foundational, already-merged architecture specifically for avoiding main-actor scene-update watchdog kills during large-graph persistence work. The OPEN DEFECT section never notes that `SettingsReset.deleteAllLocalData` is exactly the class of operation #785/#786 were built to keep off the main actor, and simply wasn't. This isn't factually wrong, but given how carefully both documents cross-reference every other PR and issue against current defects, its absence here is a notable gap for anyone using these docs to scope the fix.

---

### 2.4 Complete Codex preregistration

The following is the complete content committed before any measurement:

---

# Codex pre-registered predictions

These predictions were written before any Phase 3 measurement was created or run.

## C. Complexity and numeric predictions

**Inferred.** I predict that the dominant cost is removing each Episode from its
parent Podcast's to-many relationship array during SwiftData cascade and inverse
maintenance. For per-podcast episode counts `n_i`, I predict
`T = Θ(sum(n_i²) + N + P)`. With one podcast this is `Θ(N²)`; with an evenly
distributed fixed total it falls approximately in proportion to podcast count.

- Predicted `t(2N)/t(N)` at fixed `P=1`: **4.00**.
- Predicted time ratio, `1 × 40,000` divided by `4 × 10,000`: **4.00**.
- Predicted time ratio, `1 × 40,000` divided by `16 × 2,500`: **16.00**.
- Predicted current-implementation completion time for 10 podcasts and 53,864
  episodes on the modern Mac simulator: **30.0 seconds**.
- Range I would be surprised to fall outside: **8.0–180.0 seconds**.

## D. Off-main acceptability for VoiceOver

**Inferred. No.** Moving the same work off the main actor would prevent the
scene-update watchdog, but a blind VoiceOver user would receive no confirmation
that the destructive operation is still running. My acceptability threshold is
**3.0 seconds** of silence after confirmation. My 30.0-second point estimate is
ten times that threshold.

## E. Candidate ranking

**Inferred, fastest first: (d), (c), (b), (a).**

1. **(d) Tear down the ModelContainer and remove store files.** Predicted
   `Θ(1)` in row count. It widens database scope: removing both V10 stores also
   removes `LocalPodcastState`, `LocalEpisodeState`, `LocalAppSetting`, split and
   repair markers, and any other rows in those stores that the current reset
   omits. It still does not itself remove downloaded audio, artwork, preferences,
   or migration snapshots unless those are separately included.
2. **(c) SwiftData batch delete by model type in dependency order.** Predicted
   `Θ(N)` store work without per-object Swift materialization. If restricted to
   the same eleven mirrored types and verified for relationship behavior, it can
   preserve current database scope. It does not correct the current omission of
   the three V10 device-local model types.
3. **(b) Delete Episodes explicitly before Podcasts.** Predicted to retain the
   same entity scope and filesystem intent as current code while reducing the
   parent cascade/inverse-array cost; it remains per-object and therefore remains
   superlinear under my model.
4. **(a) Current implementation, Podcasts first.** Predicted slowest because the
   Podcast cascade begins with populated episode arrays and is followed by the
   explicit Episode pass before the single save.

---

The preregistration commit output was:

```text
[agent/reset-watchdog-diagnosis fe03910] docs: preregister reset watchdog predictions
fe039104c0d638e655d7bcb0bd67763e6ffeb288
```

No Phase 3 measurement existed before that commit.

## Phase 3: measurement

All xcodebuild measurements targeted the disposable iOS 26.5 simulator
`58857CDF-1560-410D-8F46-7381F7ADF48A` with signing disabled. No phone command
was run.

### 3.1 Real-shape completion time

Preserved source SHA-256 before and after:

```text
da1f307632a5a071c892f1d37c236bfcb890101b7a068fb7eb579387f3a19978
da1f307632a5a071c892f1d37c236bfcb890101b7a068fb7eb579387f3a19978
```

Exact structured test output:

```text
RESETREAL|pre|primaryVersion|10.0.0|localVersion|10.0.0|counts|Podcast=10,Episode=53864,QueueItem=6,ListeningSession=5,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=2,LocalPodcastState=10,LocalEpisodeState=34,LocalAppSetting=9
RESETREAL|result|candidate|a-current-podcasts-first|seconds|145.774626|save|success|baselineRssMB|268.734|peakRssMB|998.922|growthRssMB|730.188|counts|Podcast=0,Episode=0,QueueItem=0,ListeningSession=0,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=0,LocalPodcastState=10,LocalEpisodeState=34,LocalAppSetting=9|primaryIntegrity|ok|localIntegrity|ok|reopen|success|filesystemSteps|skipped
Executed 1 test, with 0 failures in 145.933 seconds
** TEST SUCCEEDED **
```

The simulator emitted, for both copied files:

```text
CoreData: error: This store file was previously used on a build with Persistence-1627 but is now running on a build with Persistence-1526.
```

The warning did not prevent open, save, integrity check, or reopen, but it is a
simulator condition and remains an Unknown for timing comparability.

### 3.2 One-parent scaling

```text
RESETSCALE|episodes|2500|podcasts|1|seconds|3.631215|save|success|primaryIntegrity|ok|localIntegrity|ok|filesystemSteps|skipped
RESETSCALE|episodes|5000|podcasts|1|seconds|11.324753|save|success|primaryIntegrity|ok|localIntegrity|ok|filesystemSteps|skipped
RESETSCALE|episodes|10000|podcasts|1|seconds|51.592070|save|success|primaryIntegrity|ok|localIntegrity|ok|filesystemSteps|skipped
RESETSCALE|episodes|20000|podcasts|1|seconds|105.632402|save|success|primaryIntegrity|ok|localIntegrity|ok|filesystemSteps|skipped
RESETSCALE|episodes|40000|podcasts|1|seconds|725.369190|save|success|primaryIntegrity|ok|localIntegrity|ok|filesystemSteps|skipped
Executed 1 test, with 0 failures in 910.638 seconds
** TEST SUCCEEDED **
```

Exact doubling arithmetic:

```text
5000/2500: 11.324753 / 3.631215 = 3.118722797
10000/5000: 51.592070 / 11.324753 = 4.555690530
20000/10000: 105.632402 / 51.592070 = 2.047454231
40000/20000: 725.369190 / 105.632402 = 6.866919395
```

### 3.3 Parent-array discriminator

```text
RESETPARENT|config|A|podcasts|1|episodes|40000|seconds|591.892130|save|success|primaryIntegrity|ok|localIntegrity|ok|filesystemSteps|skipped
RESETPARENT|config|B|podcasts|4|episodes|40000|seconds|176.969609|save|success|primaryIntegrity|ok|localIntegrity|ok|filesystemSteps|skipped
RESETPARENT|config|C|podcasts|16|episodes|40000|seconds|39.870310|save|success|primaryIntegrity|ok|localIntegrity|ok|filesystemSteps|skipped
Executed 1 test, with 0 failures in 828.361 seconds
** TEST SUCCEEDED **
```

```text
A/B: 591.892130 / 176.969609 = 3.344597603
A/C: 591.892130 / 39.870310 = 14.845435864
```

> **Turn 2 correction of the Turn 1 conclusion (2026-08-07):** Turn 1's
> statement that these points did not support stable linear or quadratic
> scaling was not supported. Regressing `ln(time)` on `ln(N)` for the five
> one-Podcast points gives slope `1.850573955969`, intercept
> `-13.263101606655`, and `R² = 0.984582008621`, which is close to quadratic.
> The fixed-total ratios `3.344597603` and `14.845435864` are close to the
> `N²/P` predictions `4` and `16`. Adjacent doubling ratios remain noisy and
> must be reported as variance, not used to erase the fitted trend. Turn 2's
> new 2×20,000 falsifier took `188.613377458` seconds; A/B/C-anchored `N²/P`
> predictions overestimated it by `56.906190%`, `87.653295%`, and
> `69.109150%`. Thus `N²/P` describes the direction of the parent-shape effect
> but is not a validated quantitative predictor.

### 3.4 Candidate remedies

Synthetic 1 Podcast × 40,000 Episodes:

| Candidate | Seconds | Save/result | Final counts | Integrity/reopen |
|---|---:|---|---|---|
| (a) current Podcasts-first | 708.438257 | success | all 14 measured types zero | `ok` / `ok` / success |
| (b) Episodes-first | 295.777705 | success | all 14 measured types zero | `ok` / `ok` / success |
| (c) SwiftData batch, dependency order | 0.005535 | `NSCocoaErrorDomain Code=134060`; failed | Podcast=1, Episode=40000; all unchanged | `ok` / `ok` / success |
| (d) remove disposable store files | 0.009515 | success | all 14 types zero | `ok` / `ok` / success |

Real 10 Podcast × 53,864 Episode copies:

| Candidate | Seconds | Save/result | Mirrored/local result | Integrity/reopen |
|---|---:|---|---|---|
| (a) current Podcasts-first | 121.419712 | success | 11 current mirrored types zero; local 10/34/9 survive | `ok` / `ok` / success |
| (b) Episodes-first | 153.079173 | success | 11 current mirrored types zero; local 10/34/9 survive | `ok` / `ok` / success |
| (c) SwiftData batch, dependency order | 0.005999 | `NSCocoaErrorDomain Code=134060`; failed | every count unchanged | `ok` / `ok` / success |
| (d) remove disposable store files | 0.027738 | success | mirrored and all local types zero | `ok` / `ok` / success |

Candidate (c)’s exact failure began:

```text
failure:Error Domain=NSCocoaErrorDomain Code=134060 "A Core Data error occurred." UserInfo={Reason=Entity named:QueueItem not found for relationship named:episode, MissingEntity=QueueItem..., Relationship=Name: episode Destination Entity:Episode}
```

The initial real-candidate command omitted its fixture-root environment variable
and failed before copying/opening a store:

```text
XCTUnwrap failed: expected non-nil value of type "String" - Set TEST_RUNNER_RESET_INCIDENT_FIXTURE_ROOT to the read-only container backup.
Executed 1 test, with 8 failures (0 unexpected) in 0.578 seconds
** TEST FAILED **
```

It was recorded and rerun once with the correct read-only source variable.

### 3.5 Opt-in mechanism

The diagnostic tests use the repository’s existing mechanism at
`EarshotTests/StoreMigrationV6toV8Tests.swift:2350-2354` in baseline source:

```swift
try XCTSkipUnless(
    ProcessInfo.processInfo.environment["RUN_SYNC_MIGRATION_SCALE"] != nil,
    "Set TEST_RUNNER_RUN_SYNC_MIGRATION_SCALE=1 to run the 242k migration profile."
)
```

With no opt-in variable, the new measurement test produced:

```text
Executed 1 test, with 1 test skipped and 0 failures
** TEST SUCCEEDED **
```

### 3.6 OPML generation

The preserved V6 store SHA before and after was identical:

```text
319de2c6934f20ce2878d870c1ae0a777244de037243a9e1b88665fe77e9646a
319de2c6934f20ce2878d870c1ae0a777244de037243a9e1b88665fe77e9646a
```

The disposable copy contained 666 podcasts, no missing feed URLs or titles,
241,759 Episodes, and 654 podcast foreign keys represented among Episodes.

```text
OPML|file|earshot-666-full.opml|subscriptions|666|fixtureEpisodes|241759|bytes|97307
OPML|file|earshot-250.opml|subscriptions|250|fixtureEpisodes|222719|bytes|37524
OPML|file|earshot-100.opml|subscriptions|100|fixtureEpisodes|175435|bytes|15853
```

The 250 and 100 files select subscriptions in descending fixture Episode count.
Validation output:

```text
xmllint --noout docs/incidents/2026-08-06-delete-all-local-data/opml/earshot-100.opml
exit_code=0
xmllint --noout docs/incidents/2026-08-06-delete-all-local-data/opml/earshot-250.opml
exit_code=0
xmllint --noout docs/incidents/2026-08-06-delete-all-local-data/opml/earshot-666-full.opml
exit_code=0
```

### 3.7 Actor-path preparation timing

The first 50,000-row run revealed a stale installed XCTest bundle because its
summary omitted the newly compiled fields. That result was rejected, and the
case was rerun with dedicated DerivedData at `/tmp/EarshotPreparationDerived`.

| Episodes | Source store-set bytes | Preparation ms | Full migration ms | Test result |
|---:|---:|---:|---:|---|
| 50,000 | 9,883,648 | 249.268 | 2,092 | 1 test, 0 failures |
| 100,000 | 19,587,072 | 361.594 | 1,276 | 1 test, 0 failures |
| 200,000 | 39,559,168 | 634.712 | 1,944 | 1 test, 0 failures |
| 400,000 | 79,593,472 | 1,082.926 | 4,628 | 1 test, 0 failures |

Each test called `StoreMigrationEngine.openOrMigrate(at:)` and measured from
actor invocation until the `.migratingMirroredStore` stage was received.

Least-squares arithmetic across the four rows:

```text
n=4 sumX=750000 sumPreparationMs=2328.500 sumXX=212500000000 sumXY=608735600.000 denominator=287500000000
preparationMs = 0.002395017 * episodes + 133.059304
fiveSecondEpisodeEstimate = (5000 - 133.059304) / 0.002395017 = 2032111.090
sumBytes=148623360 sumXBytes=42202112000000
storeSetBytes = 199.446706087 * episodes + -240417.391304
estimatedStoreSetBytesAtFiveSeconds = 405057445.984
```

**Inferred from simulator measurements.** The five-second point is an
extrapolation to 2,032,111.090 Episodes and 405,057,445.984 bytes, not a measured
crossing. Hardware timing is not established.

## Phase 4: prediction comparison

The following is the complete Phase 4 comparison:

---

# Phase 4 prediction comparison

Claims in the prediction columns are inferred unless the prediction file labels
them otherwise. Results in the measured column are measured unless explicitly
identified as a judgment or unresolved.

| Quantity | Claude Code prediction | Codex prediction | Measured result |
|---|---|---|---|
| Complexity in episode count `N` and podcast count `P` | `O(N²(1 + 1/P))`; redundant Episode pass dominates and parent cascade contributes `N²/P` | `Θ(sum(n_i²) + N + P)`; parent relationship-array maintenance dominates | The fixed-total parent ratios, `A/B = 3.344597603` and `A/C = 14.845435864`, favor a strong `sum(n_i²)` term. The single-parent doubling ratios were irregular: 3.118722797, 4.555690530, 2.047454231, and 6.866919395. These timings establish superlinear, shape-sensitive behavior but do not prove a tight asymptotic bound. |
| `t(2N)/t(N)`, `P=1` | 4.0 | 4.00 | 3.118722797 (2,500→5,000); 4.555690530 (5,000→10,000); 2.047454231 (10,000→20,000); 6.866919395 (20,000→40,000). **Turn 2 correction:** adjacent ratios are noisy, but the five-point log-log slope is 1.850573955969 with R² 0.984582008621; it was incorrect to treat ratio noise as absence of a trend. |
| `1×40,000 / 4×10,000` | 1.6 | 4.00 | `591.892130 / 176.969609 = 3.344597603`. Codex absolute error: `|3.344597603 - 4| = 0.655402397`; Claude absolute error: `|3.344597603 - 1.6| = 1.744597603`. Measurement favors Codex. |
| `1×40,000 / 16×2,500` | 1.9 | 16.00 | `591.892130 / 39.870310 = 14.845435864`. Codex absolute error: `1.154564136`; Claude absolute error: `12.945435864`. Measurement favors Codex. |
| Current algorithm, real 10-podcast/53,864-episode point estimate | 60 seconds | 30.0 seconds | Phase 3.1: 145.774626 seconds. Claude error: 85.774626 seconds. Codex error: 115.774626 seconds. Claude is closer by exactly 30.000000 seconds. A second candidate-series sample was 121.419712 seconds, 24.354914 seconds lower; the gate uses the required Phase 3.1 value. |
| Current algorithm surprise range | 15–240 seconds | 8–180 seconds | 145.774626 seconds; both ranges contain it. No disagreement is settled. |
| Off-main actor with no feedback acceptable | No | No | Not empirically measured. The measured 145.774626-second silence is above the user-specified three-second gate, so the Phase 5 judgment is “No”; this is a judgment, not a UX measurement. |
| Silence threshold where answer flips | 3 seconds | 3.0 seconds | The task defines 3.0 seconds as the VoiceOver judgment threshold. This was not independently measured. |
| Overall remedy ranking | `(d), (c), (b), (a)` | `(d), (c), (b), (a)` | `(d)` completed fastest but is non-equivalent: 0.009515 seconds synthetic and 0.027738 real. `(c)` did not complete: it failed with `NSCocoaErrorDomain Code=134060` and deleted zero rows. On synthetic stores `(b)` 295.777705 seconds beat `(a)` 708.438257; on the real copies `(a)` 121.419712 beat `(b)` 153.079173. Both complete rankings were wrong because `(c)` failed and `(a)/(b)` order depended on shape. |
| `(d)` scope | Wider database scope; both split stores and markers removed; live contexts require replacement | Wider database scope; removes all three local models and split/repair markers; downloaded audio, artwork, preferences, and snapshots remain unless separately removed | Measured database result removed all mirrored and local model rows. Filesystem timing deliberately covered disposable store files only. The production reset’s separate audio/artwork steps were excluded by the safety gate. Migration snapshots and preferences were not part of candidate `(d)`. |
| `(c)` scope | Intended same 11-model end state if dependency ordering is correct | Intended same 11-model end state and omission of three local models | Not established because the first batch operation failed in the split-container configuration. All 11 mirrored and three local counts remained unchanged; both integrity checks were `ok`, and reopen succeeded. |
| `(b)` scope | Same as current reset | Same as current reset | Confirmed for database rows: all 11 current mirrored model types became zero and all three omitted local model counts survived on the real store copy. Filesystem scope was skipped by the safety gate. |
| `(a)` scope | Current scope | Current scope | Confirmed for database rows: all 11 current mirrored model types became zero and all three omitted local model counts survived on the real store copy. Filesystem scope was skipped by the safety gate. |

## Disagreements

- Parent-shape model: the measurements favor Codex. For A/B, Codex was closer
  by `1.744597603 - 0.655402397 = 1.089195206` ratio units. For A/C, Codex was
  closer by `12.945435864 - 1.154564136 = 11.790871728` ratio units.
- Real-shape point estimate: the Phase 3.1 measurement favors Claude by exactly
  `115.774626 - 85.774626 = 30.000000` seconds. Both prediction ranges include
  the result, so the range disagreement remains unresolved.
- Complexity: the fixed-total parent discriminator favors Codex’s dominant
  parent-array term. The irregular doubling series does not establish either
  exact complexity expression, so the tight bound remains unresolved.

## Items both predictions got wrong

- **Turn 2 correction:** both predicted an exact 4.0 doubling ratio, while the
  adjacent ratios ranged from 2.047454231 to 6.866919395. Turn 1 incorrectly
  generalized that variance into absence of a quadratic trend; the log-log
  slope is 1.850573955969 with R² 0.984582008621.
- Both ranked the completing remedies `(d), (c), (b), (a)`. Candidate `(c)` did
  not complete in either shape; it failed and deleted zero rows. The `(a)/(b)`
  ordering also reversed between the one-parent synthetic and ten-parent real
  shapes.
- Both point estimates materially understated the required Phase 3.1 time:
  Claude by 85.774626 seconds and Codex by 115.774626 seconds.

## Claude Code item F, verbatim, with Codex disposition

> **1. "24 SwiftData frames and RangeReplaceableCollection.removeAll(where:)" (earshot-migration-report.md, OPEN DEFECT section; identical text in migration-state.md, OPEN DEFECT section) is a composite that matches neither crash report individually.** Counting `imageIndex:3` (SwiftData) frames directly: Report 1 (193440) has **18** SwiftData frames, and its preceding libswiftCore frames *do* include `_halfStablePartition`/`removeAll(where:)`. Report 2 (194039) has **24** SwiftData frames, but its preceding libswiftCore frame is a plain `swift_release` — no partition or `removeAll` anywhere in that trace. The docs' single sentence attributes "24 frames" + "removeAll(where:)" as if it describes one unified signature, but that combination is present in neither report as stated — 24 frames belongs to the report without removeAll, and removeAll belongs to the report with 18 frames. This is a factual, independently verifiable inaccuracy, and it matters diagnostically: the two incidents are dying at two genuinely different points in SwiftData's internals (bulk array compaction vs. ARC teardown), which is worth knowing precisely rather than blurring into one description, since it bears on where the O(n)-per-touch cost is actually coming from.

**Disposition: agree.** Direct frame counts establish the composite wording is
imprecise. The tracked document copies will distinguish report 1’s 18 SwiftData
frames plus `removeAll(where:)` from report 2’s 24 SwiftData frames plus
`swift_release`.

> **2. Unreconciled episode-count discrepancy.** The OPEN DEFECT section (both docs) states the delete "runs on the main thread over roughly 53,864 episodes." Elsewhere in the *same documents*, the presumably-same 10-podcast production store is repeatedly and precisely measured at **53,946 episodes** (e.g., migration-state.md "Preserved fixtures → Public build-155 V5 production shape": "10 podcasts and 53,946 episodes"; earshot-migration-report.md "Real build-155 V5 fixture": "10 subscriptions and 53,946 episodes"). That's an 82-episode gap the documents never explain. There's a plausible reconciling fact sitting elsewhere in the same document — "The production V5 store contained 86 duplicate episode GUID pairs... Per-podcast identity repair removed the duplicates afterward" — but 53,946 − 86 = 53,860, still 4 off from 53,864, and neither document draws this connection or otherwise accounts for the gap. Given how precisely everything else in these documents is measured and cited (down to individual 4,096-byte blocks), an unexplained, uncited "roughly 53,864" sitting next to a repeatedly-verified exact 53,946 is worth flagging as stale/imprecise.

**Disposition: agree that it is unresolved at Phase 4.** Phase 6.3 performs the
required disposable-copy reconciliation. No conclusion is forced here.

> **3. Omission, not an error: the docs don't connect this defect to the codebase's own established fix pattern.** PR #785 ("Run store migration off the main actor") and #786 ("Move store preparation off the launch watchdog path") are presented as foundational, already-merged architecture specifically for avoiding main-actor scene-update watchdog kills during large-graph persistence work. The OPEN DEFECT section never notes that `SettingsReset.deleteAllLocalData` is exactly the class of operation #785/#786 were built to keep off the main actor, and simply wasn't. This isn't factually wrong, but given how carefully both documents cross-reference every other PR and issue against current defects, its absence here is a notable gap for anyone using these docs to scope the fix.

**Disposition: agree as an editorial omission, not as a factual defect.** The
source and crash reports establish the reset’s synchronous main-actor path; the
migration engine provides the existing architectural comparison. This does not
by itself authorize reusing migration snapshot or quarantine semantics for a
Settings reset.

---

## Phase 5: gated fix and device preparation

### 5.1 Gate result

**Measured:** `T_current = 145.774626 seconds` from Phase 3.1.

**Measured:** `T_best = 121.419712 seconds`, the fastest successful
scope-preserving Phase 3.4 real-store candidate. Candidate (c) failed and cannot
be treated as fast; candidate (d) is excluded by definition because it changes
scope.

**Judgment supplied by the task:** 3.0 seconds is the maximum acceptable silent
VoiceOver interval.

Gate 3 fired because both required measured values exceed 3.0 seconds. No
shipping fix was implemented.

### 5.2 Approval decisions

`docs/incidents/2026-08-06-delete-all-local-data/approval-required.md` records
all approval decisions, drafted non-shipping strings, the three omitted V10
local models, verified-snapshot survival, VoiceOver progress/focus behavior,
partial failure, and the measured decision table. No drafted string is present
in shipping code.

### 5.3–5.7 Conditional work

- No shipping fix was written, so Phase 5.3 post-fix verification was
  inapplicable. The standing pre-PR gate was nevertheless run later for the
  diagnosis branch and returned `Result: PASS`, `1733 executed, 30 skipped,
  0 failed` on `CI-iPhone-17 (23F12FE1-0D77-4B42-B766-ADD9F27A2153)`.
- With no green post-fix CI, no simulator reproduction build was prepared.
- Build 166 was not created; marketing/build identity did not change.
- No device binary was compiled, installed, or launched.
- `morning-device-test.md` records the exact Gate 3 blocker and states that no
  artifact or truthful install command exists.

## Unknowns

- The CPU core count of modelCode iPhone18,2 was not verified from local
  evidence; all six-core CPU-percentage arithmetic is conditional.
- The crash reports cannot prove whether SwiftData was ever blocked on I/O
  during the full watchdog window; they only sample Swift/SwiftData compute at
  capture, and no other captured thread shows SQLite/Core Data/file I/O.
- The tight asymptotic complexity is not proven. Timing is strongly superlinear
  and parent-shape-sensitive, but the doubling ratios are irregular.
- The cause of the `Persistence-1627` source versus `Persistence-1526` simulator
  warning and its timing impact are not established.
- Candidate (c) was not viable in the current split-container configuration;
  whether another store-level batch mechanism can preserve current scope and
  finish below three seconds was not measured.
- The five-second preparation estimate is simulator-only extrapolation; no
  physical-device preparation timing was run.
- VoiceOver acceptability was not empirically measured. The three-second
  threshold is an explicit judgment supplied by the task.
- No fix behavior, post-fix CI result, simulator reproduction, build 166,
  device artifact, or device test exists because Gate 3 prohibited
  implementation. The diagnosis branch itself passed its pre-PR CI gate.

---

# Turn 2 — scope decisions, filesystem measurement, and gated implementation

Date: 2026-08-07. All claims below are labeled measured, derived, or inferred.
No phone command was run. Every preserved fixture read was bracketed by a
68-file SHA-256 manifest; `diff -u` returned no output after Tasks 2, 3, and 6.

## Task 1 — blocking local-state gate

### 1.1 Raw `LocalAppSetting` rows

**Measured.** The query ran against a disposable copy, never the preserved
store. Raw output, including SQLite storage types:

```text
'pk','key','value','key_type','value_type'
1,'earshot_plus_entitlement_product','','text','text'
2,'last_playing_episode_id','https://feeds.megaphone.fm/RSV2429196838|30a4cf1e-91a9-11f1-a948-8f20eed9f297','text','text'
3,'earshot_plus_entitled','false','text','text'
4,'earshot_plus_entitlement_last_synced','1786070483.862052','text','text'
5,'earshot_plus_active_subscription','false','text','text'
6,'onboarding_complete','true','text','text'
7,'last_feed_refresh','1786069997.386304','text','text'
8,'__earshot_v8_split_complete','1','text','text'
9,'__earshot_identity_repair_v1_complete','1','text','text'
'local_app_setting_count','distinct_key_count'
9,9
```

**Measured.** Preserved store-set hashes before and after were identical:

```text
da1f307632a5a071c892f1d37c236bfcb890101b7a068fb7eb579387f3a19978 default.store 114196480
5933928bfcf0494bd9d03529f37689553977d059bb4c9a7291d92ff5d211d30c default.store-wal 1091832
c123a093a161cbb06467c910381f0c6187f412d27ee94b2d42c4681fd98d818c default.store-shm 32768
69bfcf0dbb1757f45f9a23163032bdd02d4c1fda128ffb77ac627039d15b4110 earshot-local.store 200704
e23aa5bfca705df4834932ccfb76cc438a704b738deeea3db85f359344d453b9 earshot-local.store-wal 1231912
83f50e1173f9d367835e482fbd366657f2f97b9c5f7024a65de3a29d87086e2e earshot-local.store-shm 32768
```

### 1.2 Key readers and writers

**Derived from source.** All raw access routes through the local/mirrored
scope switch at `Earshot/Data/Persistence/AppSettingsStore.swift:257-277`.

- The four `earshot_plus_*` constants and their meaning are at
  `AppSettingsStore.swift:128-141`; they are read synchronously at
  `Earshot/Features/Monetization/Data/EntitlementStore.swift:83-100` and
  written after resync at `EntitlementStore.swift:186-199`.
- `last_playing_episode_id` is declared at `AppSettingsStore.swift:72`, read at
  `Earshot/Features/Player/Domain/PlaybackStartup.swift:15-24` and
  `Earshot/Features/Subscriptions/Data/FeedRefreshActor.swift:708-718`, and
  written/cleared at `Earshot/Features/Player/Data/PlayerService.swift:703-709`
  and `:1698-1710`.
- `onboarding_complete` is declared at `AppSettingsStore.swift:10`, written by
  `Earshot/Features/Settings/Presentation/SettingsStore.swift:50-51` from
  `Earshot/Features/Onboarding/Presentation/OnboardingView.swift:198-201`, and
  read at `SettingsStore.swift:60-89` and
  `Earshot/App/EarshotApp.swift:490-495`.
- `last_feed_refresh` is declared at `AppSettingsStore.swift:87-89`, read at
  `Earshot/Features/Subscriptions/Data/BackgroundFeedRefresher.swift:75-80`,
  and written at `BackgroundFeedRefresher.swift:102-109` and
  `Earshot/Features/Subscriptions/Presentation/SubscriptionsView.swift:560-566`.
- The split and identity-repair marker constants are at
  `Earshot/Data/Persistence/StoreMigration.swift:175-178`. Reads include
  `StoreMigration.swift:315-331`, `:895-907`, and `:1270-1275`; writes are at
  `:815-817`, `:924-932`, and `:1284-1290`.

### 1.3 Stop condition

**Measured:** the stop condition fired. Four rows relate directly to purchase
entitlement or subscription status. This prohibited all shipping implementation
for the remainder of Turn 2. No purchase, entitlement, paywall, StoreKit, or
shipping reset source was modified.

### 1.4 Local model properties and deletion loss

**Derived from source.** `LocalPodcastState` stores exact properties
`feedURL: String` and `refreshedAt: Date?`
(`Earshot/Data/Models/LocalState.swift:33-42`). It is written through
`LocalStateStore.setRefreshedAt` at
`Earshot/Data/Models/ActiveDownload.swift:102-117` and hydrated at `:173-181`.
Deleting it loses the last-refresh timestamp and forces refresh bookkeeping to
be re-established. Feed content can be fetched again; that exact local
timestamp is not in the feed.

`LocalEpisodeState` stores `podcastFeedURL: String`, `episodeGUID: String`,
`downloadStatusRaw: String`, and `downloadPath: String?`; `downloadStatus` is a
computed wrapper (`LocalState.swift:45-68`). Persistence is at
`ActiveDownload.swift:68-100`, repair at `:134-159`, and hydration at `:183-190`.
It is the sole durable record of download/in-flight state and the local audio
filename because the mirrored `Episode` fields are tombstones and runtime state
is transient (`Earshot/Data/Models/Episode.swift:22-40`). A feed refresh can
recreate episode metadata, but not the device transfer state or path. D1 plus
Downloads deletion intentionally loses both.

`LocalAppSetting` stores `key: String` and `value: String`
(`LocalState.swift:71-80`). Generic reads/writes are at
`Earshot/Data/Persistence/IdentityRepairService.swift:163-180`. The exact nine
facts lost are the rows printed above. StoreKit can recompute entitlement facts,
but their deletion ordering is the mandatory unresolved blocker.

## Task 2 — filesystem deletion

### 2.1 Safety gate and redirection

**Derived from source.** Production resolves Downloads from the process-global
Documents directory plus `Downloads`
(`Earshot/Features/Settings/Domain/SettingsReset.swift:41-46`). Artwork resolves
from the process-global Caches directory plus `artwork`
(`Earshot/Core/Networking/ArtworkCache.swift:81-88`); its clear primitive is
`urlCache.removeAllCachedResponses()` at `ArtworkCache.swift:172-176`.

The exact production singleton and process-global paths cannot be redirected.
The measurement therefore passed explicit test-owned URLs from environment
variables into the opt-in test at
`EarshotTests/StoreMigrationV6toV8Tests.swift:3021-3108`. Exact
`ArtworkCache.shared.clear()` was **skipped as unredirectable**. A separate
`URLCache` with the same capacities and an explicit temporary directory timed
the same `removeAllCachedResponses()` primitive. No production Documents or
Caches path was removed.

### 2.2 Non-sparse fixture

**Measured.** Thirty-four exact-size files were created under
`/tmp/earshot-reset-turn2-fs-template.DqkvVU/Downloads` using `/bin/dd` from
`/dev/zero`: 4,096-byte blocks followed by the exact remainder with
`conv=notrunc`. This writes allocated zeros; it does not seek over holes. The
artwork tree was copied into the disposable template and contained `Cache.db`
49,152 bytes, `Cache.db-wal` 177,192, `Cache.db-shm` 32,768, and three cache
payloads of 120,079, 60,424, and 10,995 bytes.

```text
RESETFS|template|files|34|logicalBytes|2215876348|allocatedBytes|2215940096|sparse|false
du -sk: 2164004 /tmp/earshot-reset-turn2-fs-template.DqkvVU/Downloads
```

The exact 34-file source manifest is in
`evidence-review/turn2-task2-download-manifest.txt`; its count is 34 and its
exact sum is 2,215,876,348 bytes. `ls/stat` allocation was 2,215,940,096 bytes,
so allocated bytes exceeded logical bytes by
`2,215,940,096 - 2,215,876,348 = 63,748` bytes.

### 2.3 Five-run timing

**Measured.** Primary series:

```text
RESETSTATS|name|downloads|samples|0.007803584,0.002035958,0.002413916,0.002141875,0.002251666|mean|0.003329400|populationStdDev|0.002240587|min|0.002035958|max|0.007803584
RESETSTATS|name|artworkClearPrimitive|samples|0.000005958,0.000005875,0.000005709,0.000003666,0.000002125|mean|0.000004667|populationStdDev|0.000001528|min|0.000002125|max|0.000005958
RESETSTATS|name|artworkDirectoryRemoval|samples|0.001223083,0.000624542,0.000710458,0.000774583,0.000664625|mean|0.000799458|populationStdDev|0.000217611|min|0.000624542|max|0.001223083
RESETSTATS|name|filesystemTotal|samples|0.009032625,0.002666375,0.003130083,0.002920124,0.002918416|mean|0.004133525|populationStdDev|0.002453953|min|0.002666375|max|0.009032625
RESETFS|artworkDirectoryRemovalSucceeded|5|of|5
Executed 1 test, with 0 failures (0 unexpected) in 0.160 seconds
** TEST SUCCEEDED **
```

Filesystem-only mean `0.004133525 / 3.0 = 0.001377842` of the allowed budget,
or `0.1377842%`; maximum `0.009032625 / 3.0 = 0.003010875`, or `0.3010875%`.
It fits within 3.0 seconds on this simulator host.

### 2.4 Open SQLite descriptors

**Measured.** The test's `/dev/fd` enumeration reported zero matching paths,
but libsqlite3 independently reported open vnodes on its worker threads in all
five confirmation runs:

```text
BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation: vnode unlinked while in use: .../artwork/Cache.db
BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation: vnode unlinked while in use: .../artwork/Cache.db-wal
BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation: vnode unlinked while in use: .../artwork/Cache.db-shm
```

This reproduces issue #690's hazard. A preliminary run also failed one removal
with `NSCocoaErrorDomain Code=513` and underlying POSIX code 1; the complete
stderr-captured confirmation series removed all five directories but still
emitted the API-violation warning every time. Reporting only; issue #690 was not
modified.

## Task 3 — complete test-only file-level reset

### 3.1 Mechanism and separation from unsupported-schema recovery

**Derived from test source.** The disposable incident shape is assembled at
`StoreMigrationV6toV8Tests.swift:3167-3212`. The reset transaction is at
`:3214-3260`, recovery at `:3266-3287`, and exhaustive verification at
`:3289-3308`. It moves both complete store sets, Downloads, artwork, and the
entire snapshot root into one quarantine under a `moving` journal; it writes a
`committed` journal before deleting quarantine; then it opens fresh V10 stores.

This reuses #797's two-phase journal/quarantine principle but not
`ModelContainerFactory.eraseLibrary`. The latter requires and revalidates a
verified snapshot and retains it (`ModelContainerFactory.swift:255-267`;
`MigrationBackupManager.swift:290-350`). Settings reset instead has no snapshot
precondition and quarantines/deletes the snapshot itself. That is the explicit
separation required by D2.

### 3.2–3.4 End-to-end results

**Measured.** All five samples include cache clear, process-local state clear,
container/context release, both store sets, snapshot, Downloads, artwork,
journal/quarantine work, and fresh store construction:

```text
RESETE2E|run|1|seconds|0.046932667|peakRssMB|269.250|primaryVersion|10.0.0|localVersion|10.0.0|primaryIntegrity|ok|localIntegrity|ok|counts|Podcast=0,Episode=0,QueueItem=0,ListeningSession=0,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=0,LocalPodcastState=0,LocalEpisodeState=0,LocalAppSetting=0|downloadsGone|true|artworkGone|true|snapshotGone|true|journalGone|true|quarantineCount|0
RESETE2E|run|2|seconds|0.041100583|peakRssMB|270.141|primaryVersion|10.0.0|localVersion|10.0.0|primaryIntegrity|ok|localIntegrity|ok|counts|Podcast=0,Episode=0,QueueItem=0,ListeningSession=0,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=0,LocalPodcastState=0,LocalEpisodeState=0,LocalAppSetting=0|downloadsGone|true|artworkGone|true|snapshotGone|true|journalGone|true|quarantineCount|0
RESETE2E|run|3|seconds|0.041597375|peakRssMB|270.188|primaryVersion|10.0.0|localVersion|10.0.0|primaryIntegrity|ok|localIntegrity|ok|counts|Podcast=0,Episode=0,QueueItem=0,ListeningSession=0,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=0,LocalPodcastState=0,LocalEpisodeState=0,LocalAppSetting=0|downloadsGone|true|artworkGone|true|snapshotGone|true|journalGone|true|quarantineCount|0
RESETE2E|run|4|seconds|0.035484084|peakRssMB|270.219|primaryVersion|10.0.0|localVersion|10.0.0|primaryIntegrity|ok|localIntegrity|ok|counts|Podcast=0,Episode=0,QueueItem=0,ListeningSession=0,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=0,LocalPodcastState=0,LocalEpisodeState=0,LocalAppSetting=0|downloadsGone|true|artworkGone|true|snapshotGone|true|journalGone|true|quarantineCount|0
RESETE2E|run|5|seconds|0.040216417|peakRssMB|270.234|primaryVersion|10.0.0|localVersion|10.0.0|primaryIntegrity|ok|localIntegrity|ok|counts|Podcast=0,Episode=0,QueueItem=0,ListeningSession=0,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=0,LocalPodcastState=0,LocalEpisodeState=0,LocalAppSetting=0|downloadsGone|true|artworkGone|true|snapshotGone|true|journalGone|true|quarantineCount|0
RESETSTATS|name|fileLevelReset|samples|0.046932667,0.041100583,0.041597375,0.035484084,0.040216417|mean|0.041066225|populationStdDev|0.003649135|min|0.035484084|max|0.046932667
RESETSTATS|name|fileLevelResetPeakRssMB|samples|269.250000000,270.140625000,270.187500000,270.218750000,270.234375000|mean|270.006250000|populationStdDev|0.379478466|min|269.250000000|max|270.234375000
Executed 1 test, with 0 failures (0 unexpected) in 0.397 seconds
** TEST SUCCEEDED **
```

The simulator emitted `This store file was previously used on a build with
Persistence-1627 but is now running on a build with Persistence-1526` when
opening the copied device stores. It did not prevent reset or verification but
limits device-time inference.

### 3.5 Crash safety

**Measured.** Every defined checkpoint passed:

```text
RESETINTERRUPT|point|afterMovingJournal|expected|rolled-back-original|counts|Podcast=10,Episode=53864,QueueItem=6,ListeningSession=5,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=2,LocalPodcastState=10,LocalEpisodeState=34,LocalAppSetting=9|consistent|true|journalGone|true|quarantineCount|0|downloadsExists|true|artworkExists|true|snapshotExists|true
RESETINTERRUPT|point|afterQuarantine|expected|rolled-back-original|counts|Podcast=10,Episode=53864,QueueItem=6,ListeningSession=5,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=2,LocalPodcastState=10,LocalEpisodeState=34,LocalAppSetting=9|consistent|true|journalGone|true|quarantineCount|0|downloadsExists|true|artworkExists|true|snapshotExists|true
RESETINTERRUPT|point|afterCommittedJournal|expected|committed-fresh|counts|Podcast=0,Episode=0,QueueItem=0,ListeningSession=0,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=0,LocalPodcastState=0,LocalEpisodeState=0,LocalAppSetting=0|consistent|true|journalGone|true|quarantineCount|0|downloadsExists|false|artworkExists|false|snapshotExists|false
RESETINTERRUPT|point|afterQuarantineCleanup|expected|committed-fresh|counts|Podcast=0,Episode=0,QueueItem=0,ListeningSession=0,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=0,LocalPodcastState=0,LocalEpisodeState=0,LocalAppSetting=0|consistent|true|journalGone|true|quarantineCount|0|downloadsExists|false|artworkExists|false|snapshotExists|false
RESETINTERRUPT|point|afterJournalRemoval|expected|committed-fresh|counts|Podcast=0,Episode=0,QueueItem=0,ListeningSession=0,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=0,LocalPodcastState=0,LocalEpisodeState=0,LocalAppSetting=0|consistent|true|journalGone|true|quarantineCount|0|downloadsExists|false|artworkExists|false|snapshotExists|false
Executed 1 test, with 0 failures (0 unexpected) in 0.330 seconds
** TEST SUCCEEDED **
```

Not tested: termination between individual quarantine moves, within an atomic
journal write, during recursive quarantine deletion, during fresh-store open,
or while the production `ArtworkCache.shared`/session is still being torn down.

### 3.6 Ordering constraint

**Derived/inferred.** Player/download/feed services, the artwork `URLSession`
and `URLCache`, every `ModelContext`, and the live `ModelContainer` must release
their store/cache descriptors before any store or cache path is moved/unlinked.
The test does this before `performReset` at
`StoreMigrationV6toV8Tests.swift:3110-3138`. If SQLite retains a descriptor,
unlink removes the pathname but the descriptor continues addressing the old
vnode; a new store at the same path is a different file. The exact libsqlite3
API-violation output in Task 2 proves the cache side of that hazard.

## Task 4 — gate

**Measured/judgment under the supplied gate:** `T_total = 0.041066225` seconds,
all five exhaustive verifications passed, and all five defined interruption
checkpoints recovered. Nevertheless **GATE FAIL** fired because Task 1's
purchase-state stop condition fired. That condition alone prohibited shipping
implementation. Tasks 5 and 7 were therefore skipped: no fix branch, shipping
code, post-fix CI, simulator reproduction, build 166, device binary, or device
test document was created in Turn 2.

## Task 6 — secondary diagnostics

### 6.1 Error 134060

**Measured.** The recursive `NSError` printer is at
`StoreMigrationV6toV8Tests.swift:2583-2686`. Exact decisive output:

```text
RESETBATCHERROR|case|two-config-no-inbound-cascade|result|success
RESETBATCHERROR|case|two-config-with-cascade|result|failure
RESETBATCHERROR|case|two-config-with-cascade|error|domain|NSCocoaErrorDomain|code|134060|description|A Core Data error occurred.
RESETBATCHERROR|case|two-config-with-cascade|error|userInfo|Reason|Optional(Entity named:Podcast not found for relationship named:episodes)
RESETBATCHERROR|case|two-config-with-cascade|error|userInfo|Relationship|Optional(Name: episodes Destination Entity:Episode)
RESETBATCHERROR|case|single-config-no-inbound-cascade|result|success
RESETBATCHERROR|case|single-config-with-cascade|result|success
Executed 1 test, with 0 failures (0 unexpected) in 6.126 seconds
** TEST SUCCEEDED **
```

`MissingEntity` contained the complete `Podcast` entity description. There was
no `NSDetailedErrors` array and no underlying `NSError`. **Derived:** code
134060 requires the combination of the two-configuration container and a batch
delete whose model has a cascade relationship. Neither two configurations
alone nor the cascade alone reproduced it.

### 6.2 Variance and WAL state

**Measured.** Each line is a fresh copied store and fresh test process:

```text
present: 140.837353500,108.028467834,169.085117333,161.438489875,151.880062167
checkpointed: 189.815376958,161.198161625,185.861821583,208.200345209,109.019837167
RESETVARIANCESTATS|mode|present|count|5|mean|146.253898142|populationStdDev|21.326099482|min|108.028467834|max|169.085117333
RESETVARIANCESTATS|mode|checkpointed|count|5|mean|170.819108508|populationStdDev|34.340095650|min|109.019837167|max|208.200345209
RESETVARIANCESTATS|mode|combined|count|10|mean|158.536503325|populationStdDev|31.110845927|min|108.028467834|max|208.200345209
RESETVARIANCECOMPARE|checkpointedMinusPresent|24.565210367|checkpointedDividedByPresent|1.167962773|percentSlower|not-supported
```

Every copied present WAL was exactly 1,091,832 primary and 1,231,912 local
bytes before and at delete. Every checkpointed WAL was those sizes before and
zero bytes after checkpoint and at delete. All ten saves succeeded. Peak RSS
ranged from 997.703 to 1000.188 MB. The 24.565210367-second mean gap is only
about 1.2 standard errors with the observed sample SDs and n=5, so a percentage
increase is not supported. The data supports only that WAL presence does not
explain the variance.

### 6.3 Cost model and falsifier

**Derived:** five-point one-Podcast natural-log regression:

```text
RESETCOSTFIT|naturalLogSlope|1.850573955969|naturalLogIntercept|-13.263101606655|rSquared|0.984582008621|powerCoefficient|1.73743337311e-06
```

The fixed-total A/B and A/C ratios remain close to the `N²/P` predictions, but
the new measurement does not validate its use as a precise absolute-time model:

```text
RESETFALSIFIER|podcasts|2|episodesPerPodcast|20000|totalEpisodes|40000|seconds|188.613377458|save|success|baselineRssMB|485.906|peakRssMB|593.062|growthRssMB|107.156|counts|Podcast=0,Episode=0,QueueItem=0,ListeningSession=0,Bookmark=0,PodcastFolder=0,FolderMembership=0,EpisodeFolderMembership=0,RecentlyExpired=0,QuickActionConfig=0,AppSetting=0,LocalPodcastState=0,LocalEpisodeState=0,LocalAppSetting=0|primaryIntegrity|ok|localIntegrity|ok
RESETMODELFALSIFIER|anchorA|predicted|295.946065000|measured|188.613377458|percentError|not-supported
RESETMODELFALSIFIER|anchorB|predicted|353.939218000|measured|188.613377458|percentError|not-supported
RESETMODELFALSIFIER|anchorC|predicted|318.962480000|measured|188.613377458|percentError|not-supported
```

**Conclusion:** exposure does concentrate in high episodes-per-podcast shapes,
but `N²/P` is not validated for threshold prediction. Therefore there is no
honest “validated-model” episodes-per-podcast 10-second threshold. The direct
one-Podcast series brackets the simulator crossing between 2,500 episodes
(`3.631215s`) and 5,000 (`11.324753s`); physical-device hardware remains
unverified.

### 6.4 Memory and issue #696

**Measured:** file-level reset peak RSS mean was 270.006250 MB, versus
997.703–1000.188 MB across the ten current real-store runs. The 2×20,000
synthetic falsifier peaked at 593.062 MB from a 485.906 MB post-seed baseline.

**Derived:** these numbers are directly relevant to open issue #696, whose body
attributes large-library jetsam to full-Episode-table materialization into a
main-actor `ModelContext`. The current reset reproduces the same large-graph
materialization at roughly one gigabyte peak. The file-level measurement avoids
that ~730 MB growth. Issue #696 was read only and not modified.

## Task 8 — record and gate output

The three user decisions are recorded verbatim as DECIDED in
`approval-required.md`; the purchase-cache ordering, artwork-cache lifetime,
failure behavior, and post-reset destination are separated as still open.

Exact normal-gate tail after the six opt-in measurement methods were added:

```text
Test Suite 'EarshotTests.xctest' passed at 2026-08-07 07:00:20.389.
    Executed 1739 tests, with 36 tests skipped and 0 failures (0 unexpected) in 52.931 (53.512) seconds
Test Suite 'All tests' passed at 2026-08-07 07:00:20.389.
    Executed 1739 tests, with 36 tests skipped and 0 failures (0 unexpected) in 52.931 (53.513) seconds
** TEST SUCCEEDED **

Local CI summary
Result: PASS
Tests: 1739 executed, 36 skipped, 0 failed
Simulator: CI-iPhone-17 (23F12FE1-0D77-4B42-B766-ADD9F27A2153)
Log: /var/folders/kf/zz3g2vln75ngjgddjrs4yg7h0000gn/T//earshot-local-ci.n5Avx3
```

Arithmetic versus Turn 1: `1739 - 1733 = 6` additional executed tests and
`36 - 30 = 6` additional skips, exactly the six new opt-in methods. No failure
count changed: `0 - 0 = 0`.

Issue #803 received the authorized Turn 2 comment at
`https://github.com/payown/earshot/issues/803#issuecomment-5218011650`. No other
issue was modified.

### 8.5–8.6 commit, PR, and closeout inventory

The first Turn 2 diagnosis commit is
`d6b179a2663ccaaec80febbfb2d7039878b7a518` (`Diagnose file-level Settings
reset gate`) and was pushed to `origin/agent/reset-watchdog-diagnosis`. Draft PR
#804 remains based on `main`, assigned to `payown`, and was updated at
`https://github.com/payown/earshot/pull/804`. No fix branch or second PR exists.

**Exact worktree inventory (20):**

```text
/Users/michaelbabcock/code/earshot | main | 8ce477e27c887de81dfb4905700d47bdb0ab4604
/Users/michaelbabcock/code/earshot-781-preparation | agent/781-migration-preparation | de522f5b03394a2faff6ffdbd3660c301f94cace
/Users/michaelbabcock/code/earshot-appstore-assembly | docs/app-store-1.0-submission-assembly | 17c46708d043bb361c86bdc7b44923da4061dbfb
/Users/michaelbabcock/code/earshot-attributed-migration-disk | agent/attribute-migration-disk-usage | 07bd9233fa7f5c17f5e98f764a04a5e096140203
/Users/michaelbabcock/code/earshot-backup-recovery | agent/backup-recovery | 7b1e64eae87bfba20341d67c55586f5c329fc263
/Users/michaelbabcock/code/earshot-build-165-identity | agent/build-165-identity | 148b8889056e6c1b8da1848aa20ad73b601b1e44
/Users/michaelbabcock/code/earshot-build-165-release | detached | 806ea10167a700f455d4e46c78056d4c80ee9210
/Users/michaelbabcock/code/earshot-device-fixture-validation | detached | a289231168b23e2c4e59a81192bbc66a4872c5ee
/Users/michaelbabcock/code/earshot-interrupted-fresh-v10 | agent/interrupted-fresh-v10 | 75ace16c973b41521e9a7bb33d40be6c51a68d9c
/Users/michaelbabcock/code/earshot-launch-announcement-order | agent/serialize-launch-announcements | 7d7459d49d29e88281fadde6d80e50a38db694f9
/Users/michaelbabcock/code/earshot-migration-handoff | agent/migration-state-handoff | 12397776b0c5e0d25a6f0f61ecab62fba2a6e8b9
/Users/michaelbabcock/code/earshot-migration-shape-fixtures | agent/migration-shape-fixtures | 83abec954e66c76debf6346c91d0d0068c71aa79
/Users/michaelbabcock/code/earshot-peak-control | detached | 806ea10167a700f455d4e46c78056d4c80ee9210
/Users/michaelbabcock/code/earshot-perf-diagnosis | agent/perf-diagnosis-2026-07-19 | 7dbac678fd1869cf6db6ba546467956687010319
/Users/michaelbabcock/code/earshot-perf-pass | agent/perf-pass | d6f5c8192efc7d14e3f32613d6b33db365b54cba
/Users/michaelbabcock/code/earshot-recovery-download-removal | agent/recovery-download-removal | 8a5bb3120472f17af5f462bb4c02cf071888db3b
/Users/michaelbabcock/code/earshot-reset-diagnosis | agent/reset-watchdog-diagnosis | d6b179a2663ccaaec80febbfb2d7039878b7a518
/Users/michaelbabcock/code/earshot-v10-cold-launch | agent/v10-cold-launch | ae34315abb82c875541c19880da9acefa203445a
/Users/michaelbabcock/code/earshot-v10-null-tombstone | agent/v10-null-tombstone | 7304fee316fd25f102979638bc06793ffa17d38b
/Users/michaelbabcock/code/earshot-v5-production-migration | agent/v5-production-migration | c261dce2753046706e97be37d4b9bd6f4bb52e2f
```

The complete 82-line `git branch -vv` output is retained at
`evidence-review/turn2-closeout-branches.txt` (12,032 bytes); the complete
80-line worktree porcelain output is at
`evidence-review/turn2-closeout-worktrees.txt` (2,996 bytes). No branch or
worktree was deleted, renamed, or pruned.

**Exact stash inventory (unchanged):**

```text
stash@{0}: On swift: stray manual build-number prebump 155 (deploy script owns this)
stash@{1}: On tech-debt/issue-656-swift-ci: unintended dart-format reformat from pre-commit hook (env SDK drift, unrelated to issue #656)
stash@{2}: On (no branch): unrelated dart-format noise, pre-rebase
stash@{3}: On fix/issue-653-position-throttle-guard: pre-commit dart-format side effect (unrelated to issue #653, dart formatter version drift) - attempt 2
stash@{4}: On fix/issue-653-position-throttle-guard: pre-commit dart-format side effect (unrelated to issue #653, dart formatter version drift)
stash@{5}: On swift: stray swiftui build bump 121->122 (set aside before #444)
stash@{6}: On feature/swift6-strict-concurrency: preflight-noise: PROMPT.md/Claude backup
stash@{7}: On swift: non-swift WIP: Flutter queue/search screens + CLAUDE.md rewrite
```

The diagnosis worktree has no tracked changes after the closeout commit. Its
untracked files are the copied two `.ips` files, copied root Markdown files,
the existing `evidence/` directory, Turn 1 analysis helpers/artifacts, and these
Turn 2 artifacts:

```text
evidence-review/pr-body-turn2.md
evidence-review/turn2-closeout-branches.txt
evidence-review/turn2-closeout-stashes.txt
evidence-review/turn2-closeout-worktrees.txt
evidence-review/turn2-issue-696.json
evidence-review/turn2-issue-803-comment.md
evidence-review/turn2-local-ci.log
evidence-review/turn2-task2-artwork-manifest.txt
evidence-review/turn2-task2-backup-after.sha256
evidence-review/turn2-task2-download-manifest.txt
evidence-review/turn2-task2-filesystem-stderr-rerun.log
evidence-review/turn2-task2-filesystem.log
evidence-review/turn2-task3-backup-after.sha256
evidence-review/turn2-task3-backup-before.sha256
evidence-review/turn2-task3-e2e.log
evidence-review/turn2-task3-interruptions.log
evidence-review/turn2-task6-backup-after.sha256
evidence-review/turn2-task6-backup-before.sha256
evidence-review/turn2-task6-batch-error.log
evidence-review/turn2-task6-cost-fit.txt
evidence-review/turn2-task6-falsifier-model.txt
evidence-review/turn2-task6-falsifier.log
evidence-review/turn2-task6-variance-stats.txt
evidence-review/turn2-task6-variance.log
evidence-review/turn2-test-harness-citations.txt
```

Three temporary disposable roots remain and may be lost on reboot or temp
cleanup: `/tmp/earshot-reset-turn2-fs-template.0OOK6D` (failed/empty setup),
`/tmp/earshot-reset-turn2-fs-template.DqkvVU` (measurement template), and
`/tmp/earshot-reset-turn2-task1.wpbVYi` (Task 1 disposable store copy). All
essential conclusions and exact result lines are committed in this document;
the raw untracked logs and temp fixtures remain at risk of loss.

The main checkout remains exactly at `8ce477e` and has only the four required
untracked evidence files plus the intentionally untracked `android/` directory.
None was staged, modified, moved, or deleted.

## Turn 2 Unknowns

- Whether D1 intentionally authorizes deleting the four cached Plus
  entitlement/subscription facts, and the required resync ordering before a
  purchase gate reads the empty cache.
- The safe shutdown/lifetime boundary for the production
  `ArtworkCache.shared` and its `URLSession`; the exact singleton was not
  redirectable, and disposable cache unlink reproduced issue #690.
- The correct post-reset destination after deleting `onboarding_complete`.
- Crash behavior between individual quarantine moves, within an atomic journal
  write, during recursive quarantine cleanup, during fresh-store open, and
  during production service/cache teardown.
- Physical-device file-level timing and the timing effect of the simulator's
  Persistence-1627-versus-1526 warning.
- A quantitatively validated cost model and device-specific 10-second
  episodes-per-podcast threshold. The Turn 2 falsifier disproved using the
  simple A/B/C-anchored `N²/P` model for that purpose.
- No Turn 2 shipping fix, post-fix CI, simulator reproduction, build 166,
  device binary, or device test exists because the mandatory purchase-state
  stop condition fired.
## Turn 3 — authorized implementation

### Entitlement resync gate (measured/source-derived)

`EntitlementStore.resync()` is called at cold launch by
`AppRuntime.activateEntitlements` (`Earshot/App/EarshotApp.swift:745-750`,
and its launch task at `:1001-1005`), by the StoreKit transaction listener only
when an update signal arrives (`Earshot/Features/Monetization/Data/EntitlementStore.swift:152-163`),
and after the explicit Restore Purchases action (`Earshot/Features/Settings/Presentation/SettingsScreen.swift:189-196`,
`EntitlementStore.swift:140-149`). There is no reset-completion, onboarding,
scene-activation, or view-appearance resync. A user who resets and remains in
the process therefore does not trigger a resync; the in-memory value remains
until a later launch or StoreKit event. Issue [#805](https://github.com/payown/earshot/issues/805)
records the cold-launch-only persisted-state window. Cached entitlement gates
the Settings Plus section (`Earshot/Features/Settings/Presentation/SettingsScreen.swift:20-38`),
subscription-cap/read-only behavior (`Earshot/Features/Subscriptions/Presentation/SubscriptionsView.swift:243-274`),
OPML/import/subscription cap calls (`Earshot/App/RootView.swift:436`,
`Earshot/Features/Onboarding/Presentation/OnboardingView.swift:79`,
`Earshot/Features/Subscriptions/Data/SubscriptionRepository.swift:136-141`),
and active-subscription presentation in the paywall
(`Earshot/Features/Monetization/Presentation/PaywallView.swift:232-288`).

### Cache teardown (measured)

`ArtworkCache` owns a disk-backed `URLCache` and a dedicated `URLSession`
(`Earshot/Core/Networking/ArtworkCache.swift:64-114`). Turn 3 added locked,
replaceable resources, `tearDown()`, and `resetShared()`
(`ArtworkCache.swift:20-47`, `:225-236`). The disposable reconstruction test
removes and recreates the cache directory, stores and retrieves a response, and
captured redirected stderr contained zero bytes matching
`BUG IN CLIENT OF libsqlite3.dylib`. The simulator nevertheless emitted
unified-log API-violation lines for Cache.db, -wal, and -shm while unlinking;
therefore this run proves the client teardown/reconstruction path but does not
prove Apple's URLCache descriptors close synchronously. Issue #690 remains open.

### Shipping implementation (measured)

`AppRuntime.resetLocalData()` rejects a second in-flight reset, posts the
existing player shutdown notification, releases service contexts and cache
resources, publishes `.unavailable`, runs the file transaction detached, then
opens a fresh V10 container before reinstalling it
(`Earshot/App/EarshotApp.swift:648-680`). `SettingsReset.performFileReset` uses
a moving/committed journal and quarantine, moves both store sets, backups,
Downloads, and artwork, and creates no snapshot precondition or retained
snapshot (`Earshot/Features/Settings/Domain/SettingsReset.swift:30-115`). The
existing success announcement remains byte-for-byte and 0.5 seconds after
success (`Earshot/Features/Settings/Presentation/DataSettingsView.swift:117-124`);
the new container's empty `onboarding_complete` state causes onboarding to be
shown by the existing RootView path. The exact VoiceOver ordering at the
announcement/onboarding transition remains an on-device behavioral unknown.

Five shipping-seam runs against disposable copies of the real incident shape
reported:

```
SHIPPINGRESET run 1 0.008333375 s
SHIPPINGRESET run 2 0.005568292 s
SHIPPINGRESET run 3 0.007474375 s
SHIPPINGRESET run 4 0.006599042 s
SHIPPINGRESET run 5 0.006395542 s
mean 0.006874125 s; population SD 0.000948644 s; min 0.005568292 s; max 0.008333375 s

## Turn 4 — correctness and shipping-path timing

The 0.006874125 s figure above was the file transaction seam only; it excluded
the production container rebuild. The corrected five-run end-to-end samples were
0.034000083, 0.038343625, 0.022888542, 0.030456000, and 0.025678417 s.
Derived mean = 0.151366667 / 5 = 0.030273333 s; population SD 0.005522 s;
range 0.022888542–0.038343625 s. Container rebuild alone was
0.024064875, 0.028934208, 0.015328167, 0.014023416, 0.017185125 s;
mean 0.019907158 s, SD 0.005688045 s, range 0.014023416–0.028934208 s.
Peak RSS was 273.906, 272.094, 276.516, 289.594, 295.266 MB (mean 281.475 MB,
SD 9.230 MB). The corrected mean is below the 3.0 s ceiling.

Quarantine cleanup is lenient after the committed journal write (`try?`);
journal removal remains throwing as the completion marker. `recover()` removes
both leftovers on the next launch. The artwork test now checks reconstruction
only: the SQLite warning is unified-log output, not stderr, so the old assertion
was vacuous; the warning still appeared and #690 remains open.

Turn 3's 16.796277% checkpointing claim is withdrawn as statistically unsupported:
WAL state does not explain the variance. The falsifier's six-decimal single-run
errors are also withdrawn as over-precise; the supported result is a large
parent-shape effect with functional form unresolved.

Still untested: empty store, in-flight download, concurrent reset, injected
failure at each destructive step, termination between individual quarantine
moves, during recursive quarantine deletion, during fresh-store open, and during
service/cache teardown.
```

Every run reopened both stores as V10 `10.0.0`, integrity `ok`, all fourteen
entity counts zero, Downloads/artwork/snapshot absent. The mean is below the
3.0-second ceiling, so Gate 4 passed. Full CI after the implementation:
`1741 executed, 37 skipped, 0 failed` (the delta from Turn 2 is the new
opt-in shipping timing test, counted as one executed and one skipped in the
two CI accounting paths).

### Turn 3 corrections to Turn 2

The earlier statement that checkpointing was `16.796277%` slower is withdrawn.
The observed mean gap was about 24.6 seconds while sample SDs were about 24
and 38 seconds at n=5 (roughly 1.2 standard errors); the supported conclusion
is only that WAL state does not explain the variance. The falsifier's
six-decimal model-error percentages are also withdrawn: the data supports a
large parent-shape effect (about 15x from P=1 to P=16), but not a settled
functional form; P=2 at 188.613 s and P=4 at 176.970 s are indistinguishable
at that noise level.
