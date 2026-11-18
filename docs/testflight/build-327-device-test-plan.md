# Earshot 1.2.6 (327): internal device checks

Install the internal TestFlight update in place. Do not delete Earshot, reset its library, sign out of iCloud on a daily-use device, or change a valued podcast's settings just to create a test case. Record the device, OS, build number, episode, exact VoiceOver words and steps for any mismatch.

## Folder podcast row

1. In **Library > Folders**, open a folder containing a followed podcast. With VoiceOver, swipe to its podcast row. It should be one stop, announce its podcast title and author if available, and hint **Opens podcast episodes**.
2. Double tap the row. The podcast's episode list should open without starting audio. Use **Back**. Check that focus returns to the same podcast row or a stable nearby control.
3. On the same row, choose **Actions** in the VoiceOver rotor. **Remove from folder** should still be available. Cancel without removing a valued podcast. If you have a disposable test folder, remove and re-add one test podcast and check the announcement and list.
4. Enter the folder's **Select** mode and activate a podcast row. It should select the row, rather than navigate. Leave Select mode and check that the normal row opens episodes again. Repeat on a wide iPad layout if available.

## Onboarding and help

Onboarding is a first-launch flow. Existing installations do not have a Replay onboarding control. Use a separate fresh test installation or isolated test account if available; skip this section on a daily-use library rather than deleting it.

1. With VoiceOver, use **Next** and **Back** through all ten pages. Check that the heading receives focus and announces its title plus page number. The ordered headings are **Welcome to Earshot**; **Inbox, Queue, and Downloads**; **Find the episodes you want**; **Make actions yours**; **Choose your listening order**; **Organize with folders**; **Download and export audio**; **Your privacy and iCloud**; **Add your first podcast**; **Ready to listen**. Check swipe order at the largest accessibility text size; offscreen pages should not become extra stops.
2. On **Add your first podcast**, try Search, RSS URL and OPML only with disposable test content. Return from each sheet and check focus. With no followed podcast, **Next** should be dimmed and explain that a podcast is needed; **Skip** is available. For the final gate, follow one test podcast, then choose Next; **Start Listening** should be enabled on page ten. A synced account that already has subscriptions cannot test the empty gate without an isolated store.
3. On an existing installation, open **Settings > Help & About > Inbox, Queue, and Downloads guide**. With Wi-Fi off, confirm the **Listening workflow guide** still opens and its headings and text are readable. At the largest text size, check **Find listening controls** and **What each screen is for**. Reenable Wi-Fi afterward.
4. In **Settings > Quick Actions**, read the explanation. In a podcast episode list and in Queue, double tap should open episode details. Enabled episode actions should be in the VoiceOver **Actions** rotor in configured order. The setting choice says **Download / Remove Download**; an episode's action says **Download** or **Remove download** for its actual state. This build does not add an always-visible removal action.

## iPad Inbox selection and scope

Use a disposable podcast or episode for state-changing checks. The original anonymous iPad selection report is not considered physically resolved by simulator tests.

1. On iPad, open **Inbox**, choose **Select**, then activate an episode. VoiceOver should announce it as selected. The batch action should say **Mark 1 episode as played**. Activate it and confirm that the episode leaves Inbox and is Played in Library. Repeat using the exact gesture that previously seemed ineffective; record whether one double tap or another gesture was needed.
2. Select an episode, then have it leave the current Inbox from a second signed-in test device or another controlled update. Try once when it is the only row in the selected scope and once with other rows remaining. The old **Mark 1 episode as played** action should disappear or become disabled when no selected episode remains; focus should land on an empty-state message, **Done**, or a stable neighbor, not a vanished row. Record exact focus behavior.
3. For a disposable test podcast, select its Inbox episode on iPad, then change that podcast's Inbox inclusion on the other device. Before the iPad refresh finishes, a stale batch action must not mark the episode Played. Restore the test setting afterward. Likewise, remove a test podcast from a selected Inbox folder on the other device; the stale folder batch action must not affect its episode. A count may briefly lag until the normal refresh.
4. Confirm **Add to queue**, **Add to folder**, and **Move to folder** still affect only selected episodes in the current scope. Do not use valued episodes for destructive or organizational tests.

## Separate open checks

- **Two-device Inbox mismatch:** Compare followed podcasts, Inbox inclusion, age/count limits, filters and iCloud status on both devices, then refresh. The forward-looking cap and reload fixes do not restore historically dismissed episodes whose reason is unknown. Send titles and settings for remaining differences.
- **Folder Run playback:** On an existing disposable run, check Pause, Resume and Stop after current around an episode boundary. Report any duplicate advancement or silence. This is a retained build 326 behavior, not a new fix in 327.
- The four Watch scenarios Michael already accepted on build 326 need no repeat for this UI-only combination. Watch handoff or offline findings beyond those exact accepted checks remain separate reports.
