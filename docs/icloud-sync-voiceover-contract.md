# iCloud Sync VoiceOver contract

Date: 2026-08-12  
Scope: `CloudSyncSettingsView` on iOS SwiftUI  
Evidence level: source and automated-test audit; physical iPhone and Designed-for-iPhone Mac verification remains required by #815.

## Reading order and focus

The screen uses a native `Form` and native sections. Expected VoiceOver order is:

1. Back button, then the `iCloud Sync` navigation title.
2. `iCloud Sync` section heading.
3. `Status`, with the current status text as its value.
4. `Last completed on this device`, with a local completion date, `Not yet recorded`, or `Unavailable` as its value.
5. The matching status explanation.
6. `What syncs` section heading and its two explanatory paragraphs.
7. `Timing` section heading and its explanatory paragraph.
8. When an account change is detected, the `Account Change` heading, action button, and explanation.

No code programmatically moves focus when an event changes. Routine CloudKit events make no VoiceOver announcement and do not intentionally steal focus. Opening the native confirmation alert is expected to move focus into the alert; cancelling or completing it is expected to return through native SwiftUI alert behavior. Both expectations require physical confirmation.

## Status name and value matrix

The status row is native `LabeledContent`: name `Status`, with one of these values and a following static-text explanation.

| State | Value | Following explanation |
| --- | --- | --- |
| Sync disabled | Unavailable in this build | This build does not have iCloud synchronization enabled. |
| Checking account | Checking iCloud | Earshot is checking whether this device can use your private iCloud database. |
| Available, no event | Available | Earshot can use your private iCloud database and synchronizes automatically. |
| Event in progress | Syncing | Earshot can use your private iCloud database and synchronizes automatically. |
| Event succeeded | Available | Earshot can use your private iCloud database and synchronizes automatically. |
| Event failed | Needs attention | The most recent iCloud operation failed. Your local changes remain saved and Earshot will try again. |
| Signed out | Signed out | Sign in to iCloud in System Settings to synchronize Earshot. Your local library remains available. |
| Restricted | Restricted | This device currently restricts Earshot from using iCloud. Your local library remains available. |
| Temporarily unavailable | Temporarily unavailable | iCloud could not be reached. Earshot will keep your local changes and try again later. |
| Account changed | Paused after account change | Synchronization is paused so a different iCloud account cannot silently merge with this library. Your local library has not been deleted. |

The row and explanations are static text; they have no button trait, hint, or custom action. State is always expressed in text and does not depend on color or an icon.

The second native `LabeledContent` row is named `Last completed on this device`.
It reports the newest successful setup, import, or export event completed by this
device, persists that value across launches, and clears it when an iCloud account
change is detected. It deliberately does not say `Last synced`: Apple's public
event stream cannot prove that every other device has received the changes.
While account access is available but no completion has been observed it says
`Not yet recorded`; in other availability states it says `Unavailable`.

## Account-change action

When account state is `accountChanged`, the native button is named `Use Current iCloud Account` and has the button trait. While its task is running, its name becomes `Connecting…` and it is disabled, exposing both a spoken busy label and disabled state without introducing a new focus target.

Activating it opens a native alert titled `Connect to Current iCloud Account?` with this message:

> Earshot will keep this device's library, discard the previous account's local sync cache, and merge with any Earshot library in the current iCloud account. The previous account's iCloud data is not changed.

The alert actions are native buttons named `Connect` and `Cancel`; Cancel has the cancel role. The initiating button's following static text says: `This device's library is kept. Earshot discards only the previous account's local sync cache before connecting.`

## Audit result and open physical checks

Source audit found no missing accessible names, custom controls, icon-only meaning, or code-driven routine speech. Native controls provide their roles and states. Automated tests cover every status string and distinguish in-progress and failed events.

One acceptance gap remains: a persistent failure that appears while the screen is already open changes visible text but is not explicitly announced, and the requested account-connect operation has no one-time spoken success or failure result. Adding those announcements would change accessibility semantics and therefore requires Michael's explicit approval before implementation.

Physical verification must record the exact spoken output, focus location after opening/dismissing the alert, disabled/busy announcement while connecting, Dynamic Type layout, absence of routine sync chatter, and behavior on both iPhone and the Designed-for-iPhone Mac build.
