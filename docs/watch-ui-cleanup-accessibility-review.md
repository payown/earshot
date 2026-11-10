# Watch UI cleanup accessibility review

Source review against `.claude/rules/accessibility.md` and the repository's
`earshot-accessibility` checklist. Michael approved the specific Home summary,
secondary navigation names, and focus-return semantics for this cleanup.

| Check | Source result | Physical acceptance |
| --- | --- | --- |
| Labels, values, traits | Home has one named Now Playing link with episode, podcast, state, device, position and hint. The two device selectors retain their names and selected traits. Moved speed and chapter choices retain their names and selected traits. Native buttons and links retain button traits. | Hear the exact sequence with VoiceOver. |
| Stale and offline state | Saved and unreachable iPhone positions say current state is unverified. Existing phone status, refresh, continuation and transfer messages remain reachable. | Check unreachable phone and saved media availability. |
| Focus | Secondary screens return focus to their originating link; Now Playing returns to the Home summary. Position changes do not request focus. | Verify push, back, and live status updates. |
| Magic Tap and rotor | Home and Now Playing keep the shared resolver. The three secondary screens attach the same Magic Tap action with Watch control context. No episode rotor actions changed. | Verify once per gesture while playing, paused and buffering. |
| Announcements | Existing speed, sleep timer, playback and handoff methods remain the action targets and retain their announcements. No announcement was added for merely selecting controls. | Check announcement timing and no double speech. |
| Text and controls | New content uses native List rows and semantic caption text; no fixed height, custom gesture, animation, or color-only state was added. | Check largest text, contrast, touch and scroll reachability. |

Code review found no new unlabeled icon controls, empty accessibility values,
drag-only actions, or changes to iPhone tab order, purchase UI, or Quick Actions.
Simulator Watch tests verify the single Home link and navigation to iPhone
controls. They cannot establish VoiceOver focus timing, paired audio behavior,
or secondary-screen accessibility with a real episode; those remain hardware
acceptance gates. The repository's prior watch review and device checklist
remain applicable.
