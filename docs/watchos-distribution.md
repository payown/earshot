# Integrated Apple Watch TestFlight candidate

Candidate: Earshot **1.2.5 (299)** from `feature/watchos-architecture`. Target: existing App Store Connect app `6770760602`, **Internal Testing Group** only. This is an internal evaluation build; do not submit for public review or merge before Michael's physical-device approval.

## Current blocker

The signed archive stopped at provisioning. Xcode reports no configured Apple developer account and cannot provision `media.payown.earshot.watchkitapp` or `media.payown.earshot.watchkitapp.widgets`. The five installed profiles cover only the iPhone bundle. `asc bundle-ids list` returns Apple's **PLA Update available** response, explicitly requiring Account Holder Michael Babcock to accept the updated Program License Agreement before membership resources can be used. Apple confirms this requirement in [Roles and access](https://developer.apple.com/help/account/access/roles/). The assistant must not accept a legal agreement for Michael.

## Resume after the account holder accepts the agreement

1. Sign in to [Apple Developer Account](https://developer.apple.com/account/) as Account Holder, review and accept the pending Program License Agreement. Verify `asc bundle-ids list` succeeds.
2. Register the two watch bundle identifiers and their approved capabilities if they do not already exist: App Groups on both targets; the existing `iCloud.media.payown.earshot` CloudKit container on the watch app. Create App Store provisioning profiles for both watch bundles with the installed Apple Distribution certificate. Do not edit phone entitlements or production signing settings.
3. In this linked worktree, run the signed archive with command-line signing overrides:

   ```bash
   xcodegen generate
   xcodebuild archive -project Earshot.xcodeproj -scheme Earshot -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/EarshotWatch299.xcarchive -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=72PH974742
   ```

4. Confirm `Earshot.app`, its `PlugIns/EarshotWatch.app`, and the nested `PlugIns/EarshotWatchWidgets.appex` have the expected bundle IDs and version **1.2.5 (299)**. Confirm the watch Info.plist has `WKRunsIndependentlyOfCompanionApp = true`, `UIBackgroundModes = audio`, and `EarshotCloudKitEnabled = YES`. Inspect the signed entitlements for the approved App Group and existing CloudKit container.
5. Create the export-options plist and export:

   ```bash
   cat > /tmp/EarshotWatchExportOptions.plist <<'PLIST'
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0"><dict>
     <key>method</key><string>app-store-connect</string>
     <key>teamID</key><string>72PH974742</string>
     <key>signingStyle</key><string>automatic</string>
     <key>uploadSymbols</key><true/>
   </dict></plist>
   PLIST
   xcodebuild -exportArchive -archivePath /tmp/EarshotWatch299.xcarchive -exportPath /tmp/EarshotWatch299Export -exportOptionsPlist /tmp/EarshotWatchExportOptions.plist -allowProvisioningUpdates
   asc publish testflight --app 6770760602 --ipa /tmp/EarshotWatch299Export/Earshot.ipa --group 'Internal Testing Group' --wait --notify
   ```

6. Check App Store Connect/TestFlight processing and record the actual uploaded build number and availability. Use the one-session `docs/watchos-device-testing.md` guide. No simulator result substitutes for that physical watch pass.

The existing `tool/swiftui-testflight.sh --test` can upload internal builds, but its fallback export profile map contains only the iPhone bundle. Use the explicit archive/export path above until a watch-aware fallback has been validated.
