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
| `t(2N)/t(N)`, `P=1` | 4.0 | 4.00 | 3.118722797 (2,500→5,000); 4.555690530 (5,000→10,000); 2.047454231 (10,000→20,000); 6.866919395 (20,000→40,000). Neither prediction described a stable measured ratio. |
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

- Both predicted a stable 4.0 doubling ratio. The four observed ratios ranged
  from 2.047454231 to 6.866919395 and did not form a stable 4.0 series.
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
