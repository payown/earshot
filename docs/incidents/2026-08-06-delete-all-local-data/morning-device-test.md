# Build 166 reset test — VoiceOver runbook

Build 166 was compiled locally and was not installed or launched by this run.
Run the simulator reproduction first. Only then, if the simulator is clean,
install the device build. The device test permanently destroys the on-device
library; the Mac container backup is the only copy and no route back onto the
phone has been proven.

1. Simulator: from the repository root run `xcodebuild build -project Earshot.xcodeproj -scheme Earshot -destination 'platform=iOS Simulator,id=58857CDF-1560-410D-8F46-7381F7ADF48A' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`, then `xcrun simctl install 58857CDF-1560-410D-8F46-7381F7ADF48A /Users/michaelbabcock/Library/Developer/Xcode/DerivedData/Earshot-doqmtcyyuaifghbaeruvqgvrqzxy/Build/Products/Debug-iphonesimulator/Earshot.app` and `xcrun simctl launch 58857CDF-1560-410D-8F46-7381F7ADF48A media.payown.earshot`. Seed only a disposable simulator container by copying a temporary copy of the build-165 backup's `Library/Application Support`, `Documents`, and `Library/Caches/artwork` into the path from `xcrun simctl get_app_container 58857CDF-1560-410D-8F46-7381F7ADF48A media.payown.earshot data`; the preserved backup is never modified. Enable VoiceOver and open Settings → Data.
   Swipe to “Delete all local data”, activate it, and confirm “Delete
   everything”. Listen for the existing completion announcement. The expected
   result is no watchdog bounce, a fresh empty store, and onboarding appearing.
2. Device: install without connecting the phone through this run:

   ```sh
   xcrun devicectl device install app --device <device-udid> \
     /Users/michaelbabcock/Library/Developer/Xcode/DerivedData/Earshot-doqmtcyyuaifghbaeruvqgvrqzxy/Build/Products/Release-iphoneos/Earshot.app
   ```

   The install command is intentionally for the user’s later run. Do not
   launch or delete data until the app is installed and VoiceOver is active.
3. Open Earshot and listen for the normal launch/onboarding focus. Navigate to
   Settings → Data → Delete all local data. Activate the destructive button,
   confirm “Delete everything”, and wait. Do not force-quit during the reset.
4. Pass: the app remains responsive, the existing “All local data deleted.
   Podcasts you follow and downloads removed.” announcement is heard, and the
   onboarding screen appears with its normal focus. Failure: a Home Screen
   bounce, watchdog termination, missing announcement, or a return to the old
   library. Capture the exact behavior and stop.
5. At the moment the announcement and onboarding transition coincide, listen
   specifically for whether the announcement is complete or clipped and whether
   VoiceOver focus lands on onboarding before or after the announcement. This
   run intentionally changes no announcement wording or focus-management code.

The point of no return is confirmation of “Delete everything”: the store files,
device-local settings, migration snapshot, downloads, and artwork are then
removed. Recommended order: simulator first, device second.
