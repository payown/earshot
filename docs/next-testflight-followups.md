# Next TestFlight follow-ups

## Unfollow in Podcast Settings

Implemented for version 1.2.2, build 264, at Michael's request on 2026-09-09.
Build 263 does not include this control.

Podcast Settings now has a native Unfollow button for followed podcasts. It
names the podcast in a confirmation and uses the existing centralized removal
behavior. Cancel leaves the podcast unchanged. Successful removal closes the
settings and the owning episode list; its announcement waits for dismissal.
Existing configurable row, rotor, swipe, and context-menu actions are unchanged.

Automated checks cover confirmation, cancellation, removal, navigation back to
Library, and the largest Dynamic Type size. Physical VoiceOver focus after
removal remains an on-device check; it is not established by XCTest.
