# Historical Apple Watch TestFlight candidates

This page preserves the 309–313 distribution and failure history. Its original
build 309 instructions below are historical; they are not a current upload plan.
Build 314 archive and upload evidence is in
[the build 314 quality report](watchos-playback-quality-314.md). Verify live App
Store Connect processing and group assignment before describing any build as
available to testers. The combined Duo, iPad and Watch source is being
integrated through reviewed PRs; a new internal candidate has not been uploaded.

Earshot **1.2.6 (309)** is the internal evaluation candidate from `feature/watchos-126-integration` for App Store Connect app `6770760602`, **Internal Testing Group** only. Do not submit for public review or merge before Michael's physical-device approval.

## Version and validation history

App Store Connect's latest processed 1.2.6 build before the watch integration was **306**. Build **307** was signed and uploaded, but Apple rejected it with validation error **90680**: the watch app was embedded in `Earshot.app/PlugIns` instead of `Earshot.app/Watch`. The failed upload reserves 307; App Store Connect reported **308** as the next available build number. `project.yml` now uses XcodeGen's native **Embed Watch Content** phase, which sets the Watch destination. Build **308** passed bundle validation and reached processing, but Apple rejected four App Intent descriptions with error **90626** because they used the word “Apple.” Those descriptions have been corrected. The failed upload reserves 308; App Store Connect reports **309** as the next available build. The regenerated project must be used for 309.

The Apple Developer Program License Agreement has been accepted. Team `72PH974742` owns the two watch App IDs. Both have the approved `group.media.payown.earshot.watch` App Group; the watch app also has the existing `iCloud.media.payown.earshot` container. App Store profiles for the phone, watch app and widget extension are installed. No phone signing, entitlement or purchase UI settings were changed.

## Build and export

From the linked worktree, regenerate the project, then archive with command-line signing overrides. The Xcode/App Store Connect API authentication key may be supplied through Xcode's `-authenticationKeyPath`, `-authenticationKeyID` and `-authenticationKeyIssuerID` options when needed; keep the private key out of the repository and logs.

```bash
xcodegen generate
xcodebuild archive -project Earshot.xcodeproj -scheme Earshot -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/EarshotWatch309Signed.xcarchive -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=72PH974742
```

The archive must contain `Products/Applications/Earshot.app/Watch/EarshotWatch.app` and the watch widget at `Watch/EarshotWatch.app/PlugIns/EarshotWatchWidgets.appex`. All three bundles must report **1.2.6 (309)**. Confirm the watch Info.plist declares independent installation and background audio, and inspect the signed entitlements for the watch App Group and existing CloudKit container.

Export with `method = app-store-connect`, `destination = export`, `teamID = 72PH974742`, `signingStyle = manual`, and an Apple Distribution certificate. The `provisioningProfiles` dictionary maps the three bundle IDs to the installed App Store profile names. The initial 307 export used:

- `media.payown.earshot`: `Earshot App Store Build 205`
- `media.payown.earshot.watchkitapp`: `Earshot Watch App Store 307 Final`
- `media.payown.earshot.watchkitapp.widgets`: `Earshot Watch Widgets App Store 307 Final`

Profile names contain 307 but their contents are independent of build number. Verify they remain active before reuse. Export with `xcodebuild -exportArchive -archivePath /tmp/EarshotWatch309Signed.xcarchive -exportPath /tmp/EarshotWatch309Export -exportOptionsPlist /tmp/EarshotWatch309ExportOptions.plist -allowProvisioningUpdates`. Verify the IPA's bundle layout, signatures and entitlements before upload.

Upload only to the existing internal group:

```bash
asc publish testflight --app 6770760602 --ipa /tmp/EarshotWatch309Export/Earshot.ipa --group 0d4027e4-f63b-4798-a882-5c8c29b16d89 --test-notes "$(cat docs/testflight/build-309-notes.txt)" --locale en-US --wait --notify --timeout 30m
```

Check App Store Connect's upload validation, processing, build-group assignment and availability. A committed upload alone does not establish that TestFlight is ready. Use the one-session `docs/watchos-device-testing.md` guide after processing. The existing `tool/swiftui-testflight.sh --test` fallback profile map contains only the iPhone bundle, so the explicit archive/export path is used for this integrated build.

## Verified internal distribution

The signed 309 archive and export succeeded. The IPA contains the watch app in the iPhone app's `Watch` directory, with its widget in the watch app's `PlugIns` directory. All bundles report 1.2.6 (309); signatures verify, and the watch has the approved App Group and CloudKit entitlements with `get-task-allow = false`. App Store Connect build `02931f5f-0fa3-462b-b152-4698f6d508b9` is **VALID**, upload **COMPLETE**, and internal state **IN_BETA_TESTING**. The existing **Internal Testing Group** receives all builds and includes 309. Test notes are present; `autoNotifyEnabled` is true. Hardware validation is still required before merge or public release.

## Build 310 integrated evaluation

The signed archive at `/tmp/EarshotWatch310Signed.xcarchive` was built from `test/watchos-126-310` at `d6ecea38` with the same command-line signing overrides and the existing three App Store profiles. The export at `/tmp/EarshotWatch310Export/Earshot.ipa` used `/tmp/EarshotWatch310ExportOptions.plist`, copied from the validated 309 profile map. The iPhone, independent watch and watch widget bundles all report **1.2.6 (310)**. `codesign --verify --strict` passed for all three; the watch entitlements include team `72PH974742`, `group.media.payown.earshot.watch`, `iCloud.media.payown.earshot`, and `get-task-allow = false`. The watch Info.plist has `WKRunsIndependentlyOfCompanionApp = true` and `UIBackgroundModes = audio`.

App Store Connect build `45f0ac2e-997e-4a98-9831-8ae65f1bd8f8` is **VALID**, and its internal beta state is **IN_BETA_TESTING**. The existing Internal Testing Group has all-build access and includes 310. Chapter 115 English test notes match `docs/testflight/build-310-notes.txt` and `docs/kashe.md`. `autoNotifyEnabled` is true; the CLI returned `notified: false` because the already assigned all-builds group was skipped. TestFlight availability is verified, but individual notification delivery is not. Physical VoiceOver, Watch Connectivity and handoff behavior remain for Michael's acceptance pass. This build has not been merged to `main` or released publicly.

## Build 311 queue evaluation candidate

The source is `test/watchos-126-311`, integrating PR #1047 from `fix/watch-queue-sync-311` on top of build 310. `project.yml` was regenerated with XcodeGen 2.46.0. The signed archive at `/tmp/EarshotWatch311Ready.xcarchive` was produced with Xcode 27.2 and command-line automatic-signing overrides only. Export used the unchanged App Store profile mapping in `/tmp/EarshotWatch311ExportOptions.plist` and produced `/tmp/EarshotWatch311Export/Earshot.ipa`. Its phone, independent watch and widget bundles all report **1.2.6 (311)**, reside in the correct `Watch` and `PlugIns` directories, and pass strict signature verification. The watch's distributed signature has the approved App Group and existing CloudKit container with `get-task-allow = false`. Its Info.plist declares independent installation and background audio. No signing project settings or entitlements were edited.

Apple's export created an `AWAITING_UPLOAD` placeholder for 311, so `next-build-number` reported 312 before the actual publish command. That placeholder alone was not a processed build. The actual upload `79a1d1c1-c5eb-4c93-8a3c-aef97affc36d` is now **COMPLETE** and the processed build is **VALID**. App Store Connect reports **IN_BETA_TESTING** for both Internal Testing Group and Public Testers. External beta review is **APPROVED**. Public Testers is explicitly assigned to 311 and its existing link is `https://testflight.apple.com/join/u8dj5UTr`. Chapter 116 English notes match `docs/testflight/build-311-notes.txt`. `autoNotifyEnabled` is true, but the initial internal publisher returned `notified: false` because the all-builds group already had access; individual notification delivery is unverified. This is an external TestFlight beta, with no `main` merge or public App Store release. A public announcement was sent through Mona from `@payown@dragonscave.space` with the build number, watch features, queue improvements, VoiceOver feedback, and the Public Testers link.

Exact local build commands, run from `test/watchos-126-311` in its linked worktree:

```bash
xcodegen generate
xcodebuild archive -project Earshot.xcodeproj -scheme Earshot -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/EarshotWatch311Ready.xcarchive -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=72PH974742
xcodebuild -exportArchive -archivePath /tmp/EarshotWatch311Ready.xcarchive -exportPath /tmp/EarshotWatch311Export -exportOptionsPlist /tmp/EarshotWatch311ExportOptions.plist -allowProvisioningUpdates
```

`Earshot` builds the iPhone/iPad app with the embedded watch app and widget; `EarshotWatch` runs the watchOS unit and UI targets. The export options reuse the approved three-profile mapping described above. The build was first uploaded to Internal Testing Group with `asc publish testflight --app 6770760602 --ipa /tmp/EarshotWatch311Export/Earshot.ipa --group 0d4027e4-f63b-4798-a882-5c8c29b16d89 --test-notes "$(cat docs/testflight/build-311-notes.txt)" --locale en-US --wait --notify --timeout 30m`. The same build was then added to Public Testers and submitted for external beta review with `asc builds add-groups --build-id 79a1d1c1-c5eb-4c93-8a3c-aef97affc36d --group 9a7512e9-a451-4917-9554-51931777c252 --submit --confirm`.
