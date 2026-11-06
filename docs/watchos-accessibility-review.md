# Earshot Apple Watch accessibility review

Reviewed 2026-11-06 against `/Users/michaelbabcock/.claude/agents/earshot-accessibility.md` and `.claude/rules/accessibility.md`. Scope: all new watch SwiftUI views, widget, and the two new iPhone Settings destinations. Rechecked after merging the complete 1.2.6 Duo/iPad branch at `f34d2897`; its iPad list/detail code is retained from that branch, while the watch integration adds only the two Settings destinations and the process-owned connectivity startup to the phone UI. This is a **code and simulator review**; Michael's physical VoiceOver pass remains the release gate. No GitHub issue number was assigned to this implementation, so this report is kept with the branch instead of posting an issue comment.

## VoiceOver

| Check | Result | Evidence or remaining work |
| --- | --- | --- |
| Labels and roles | Code pass; hardware pending | Episode Play uses the title in its label. Details, phone/watch controls, download status and widget have text labels. Native SwiftUI buttons, links, toggles and slider provide roles. Verify actual spoken output on device. |
| Hints | Code pass | Non-obvious feed input, playback device transfer and phone download requests have outcome hints. Obvious text buttons rely on labels. |
| Empty values | Pass | No `.accessibilityValue("")` in new views. |
| Existing iPhone tab order | Pass | `RootView.swift` still declares Inbox, Queue, Library, Downloads, Settings. |
| Migration sheet | N/A | Unchanged. |
| Gesture alternatives | Pass in code | Queue has Move Up, Move Down and Remove actions; seek uses an adjustable Slider; no drag-only watch action was added. |
| Episode action terminology and order | Code pass; hardware pending | Supported watch actions use Earshot labels and follow the phone's configured order after Watch Connectivity import, cached for offline use. Direct double tap always Plays. Confirm actual watchOS rotor order on hardware; iOS rotor reversal must not be assumed. |
| Focus after list changes | Code pass; hardware pending | Inbox, Queue, Downloads and Bookmarks refocus a named heading after a 350 ms collapse delay. Episode download actions refocus their replacement control. Test actual VoiceOver behavior, including Watch UI sizes. |
| Announcements | Code pass; hardware pending | Speed, sleep timer, bookmark capture, queue edits, download completion/failure, playback and handoff outcomes, subscription errors and sync conflicts have explicit announcements. Countdown updates by minute and speaks only at five-minute marks. Check timing during real audio. |

## Layout and interaction

| Check | Result | Evidence or remaining work |
| --- | --- | --- |
| Dynamic Type | Code pass; device pending | New views use semantic fonts and native `List`/`Button`; no fixed text height or one-line essential content. Test largest watch text size. |
| Touch targets | Code pass; device pending | Interactive controls are native Buttons, NavigationLinks, Toggles and Slider in Lists. Verify target size on 42 mm watch. |
| Reduce Motion | Pass | No custom animations were added. |
| Contrast and color independence | Code pass; device pending | System colors and text statuses are used; downloaded/played states and chapter selection have spoken or text equivalents. Verify high contrast on device. |
| Digital Crown | Code pass; device pending | The app does not install a custom crown rotation handler. VoiceOver controls the crown; slider supports adjustable gestures. |

## Findings that remain open

1. VoiceOver rotor ordering, focus landing after navigation, slider adjustment, background announcements and Bluetooth route feedback require Michael's physical watch test. Simulator UI tests cannot certify them.
2. A live two-device run must verify that quick-action order arrives when the phone reconnects, and that an offline watch keeps its cached order.
3. The new iPhone Settings rows add new focus stops but do not alter existing row labels or rotor actions. Michael should confirm their placement and wording during the integrated test.
4. The merged iPad panes use a selected episode and a separate, labeled Play control. The 1.2.6 iPad UI checks and physical VoiceOver reading order remain required; simulator assertions cannot certify spoken order across multiple windows.

**Gate:** Code review complete. Physical VoiceOver review **pending**; do not merge or release on this report alone.
