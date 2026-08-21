# Earshot 1.1.1 build 211 device test plan

Status: candidate preparation. Do not upload or submit until every blocking check passes.

## Install identity

- Marketing version: 1.1.1
- Build: 211
- Upgrade source: App Store 1.1.0 (210)
- Preserve the installed library; do not delete Earshot before installing.

## Blocking iPhone checks

1. Launch over App Store 1.1.0 and confirm the existing library, queue, playback position, downloads, folders, iCloud status, and Earshot Plus access remain intact.
2. With VoiceOver on, open Settings, Accessibility. Verify native controls appear immediately after Earshot Plus in this order: four episode-detail toggles, Episode description, then Podcast description.
3. Change every episode-detail toggle independently and verify Inbox, Queue, Downloads, a folder, Library search, a podcast episode list, and multi-select update without moving focus. Now Playing, played, queue position, selected state, traits, hints, and Actions rotor commands must remain.
4. Test Off, Brief, and Full descriptions. Confirm no raw HTML, empty pause, eager scrolling slowdown, or inaccessible Show Notes links.
5. Verify Library Podcast description Off reproduces the 1.1.0 row speech; Brief and Full add a value without changing the row name or actions.
6. Import an OPML file with more than ten feeds and nested folders while not entitled. Confirm ten import, the remaining count is accurate, and the app remains responsive.
7. Dismiss the paywall, relaunch, and use Settings, Data, Continue importing. Confirm no file reselection is required. Test Discard and replacement confirmation.
8. Repeat the capped import using a Sandbox purchase, then using Restore Purchases. Verified access must dismiss the import paywall and continue automatically with no duplicate feeds or folder memberships.
9. Repeat continuation once offline and once after force-quitting during import. Recovery must be safe and duplicate-free.
10. Background and foreground repeatedly, play audio, change rate, use Bluetooth/AirPlay if available, and review heat/crash behavior.

## Release decision

Any reproducible crash, missing data, duplicated subscription, lost folder, incorrect entitlement continuation, VoiceOver focus loss, missing mandatory semantics, or material scrolling regression creates a new build and reruns the affected matrix plus the full regression suite.
