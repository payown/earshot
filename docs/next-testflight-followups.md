# Next TestFlight follow-ups

## Unfollow in Podcast Settings

Requested by Michael on 2026-09-09 while build 263 was processing. This belongs
to the next TestFlight build; it is not included in build 263.

Add a visible, VoiceOver-accessible Unfollow button to Podcast Settings. Retain
the existing Actions rotor entries and use the existing unfollow confirmation
and centralized subscription-removal behavior. Cancel must leave the podcast
unchanged. After a successful unfollow, leave the deleted podcast's settings
safely and place focus on a valid destination.

Current behavior: PodcastSettingsView has no Unfollow control. Library podcast
rows offer the configurable Unfollow rotor action; episode rows in a podcast
can offer Unfollow this podcast. With VoiceOver off, Library rows also expose
swipe and context-menu actions.

Check discovery, confirmation/cancellation, navigation and focus after removal,
and that existing rotor actions still work.
