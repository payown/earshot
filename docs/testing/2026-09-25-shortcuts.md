# Earshot Shortcuts expansion

Feature: StartTesting `5c360d17-0739-413c-a777-2a50ab28548e`.
Chapter actions: `5599a486-2d5e-4559-9a8c-c2663b0a56d0`.

## Research and scope

Castro's official [Siri and Shortcuts guide](https://castro.fm/blog/siri-castro)
(published June 2020, checked September 25, 2026) describes show/category playback,
Queue-first show selection, oldest/newest unheard selection, next/end placement,
clear-current, defer-current, shuffled playback, directory search and metadata
outputs, plus a Siri guide and supplied shortcuts. It is a published baseline,
not a verified inventory of every action in the currently installed Castro app.
No newer comprehensive first-party action inventory was found.

Earshot now exposes the following equivalents and additions:

| Workflow | Earshot action |
| --- | --- |
| Play/resume, specific episode | Resume Listening, Play Episode |
| Saved show, newest/oldest unheard, Queue-first | Play an Unheard Podcast Episode |
| Public show, newest/oldest available | Search Podcast Directory → Play or Queue a Directory Podcast |
| Category selection | Get Podcasts by Category → Choose from List → Play or Queue a Directory Podcast |
| Skip seconds | Skip Forward / Skip Back, configurable seconds |
| Chapters | Next Chapter / Previous Chapter |
| Pause, play/pause, next/previous episode | Pause Listening; Control Playback |
| Complete current, advance | Clear Episode and Play Next |
| Save current for later | Control Playback: Move current episode to end and play next |
| Place selected episode next/end, remove | Change Episode Queue Placement |
| Play shuffled | Play Queue with Shuffle enabled |
| Clear all | Clear Entire Queue, with explicit system confirmation |
| Follow public show | Follow a Directory Podcast |
| Data for workflows | Get Episodes, Get Followed Podcasts, Get Playback Position; episode properties |
| Speed, continuous play, volume boost, silence trimming | Control Playback |
| Sleep timer, extend/cancel, bookmark, absolute seek | Control Playback |
| Discoverability | Ten supplied App Shortcuts; Settings → Siri and Search → Shortcuts guide |

Differences are explicit: category playback uses an explicit chart selection,
not Castro's automatic Queue/Inbox/Discover category fallback. Public show
selection does not silently choose a similarly named show. Saved-show actions
use stored episodes; public feeds expose only publisher-available history.
Library metadata stays behind the existing Siri/Search opt-in. Private feed
addresses are never returned. This is not a claim of identical natural-language
Siri interpretation or every Castro integration (e.g. sideloading/import).

## Runtime and review

Playback actions run in the existing app process and reuse its player. RootView
and background intents share the existing single-owner activation gate. A settled,
onboarded background store can finish loading without presenting a scene;
migration/recovery/onboarding still require opening the app. Cancellation/reset
checks guard operations. No signing, entitlements, reset or migration edits.

Queue operations reuse the player/repository. Independent review identified and
prompted fixes for Play Next grouped overrides, current-episode removal, defer
from the middle of a Queue, and full Queue results beyond the search-index cap.
Final review and physical-device acceptance are pending.

## Phone checks

1. Open Settings → Siri and Search → Shortcuts guide. In Shortcuts, verify Earshot
   actions and supplied shortcuts appear with clear parameter names.
2. Resume, pause, resume again; verify resume does not toggle. Assign Resume to
   Action button and a saved skip shortcut to your usual gesture. Run outside
   Earshot and locked, then test after terminating and reopening through a shortcut.
3. Skip configured/custom seconds; next/previous chapter with chapters, with no
   chapters, and at the final chapter. Check accurate failures and responsiveness.
4. On disposable Queue test episodes: clear current and advance, defer from the
   middle, next/previous, remove current, and Play Next across groups. Confirm
   played state, position, retained unrelated episodes and download preference.
5. Choose a specific saved episode with duplicate titles in different shows.
   Try Get Queue, choose a late item, and Play Episode. Test Siri/Search opt-out.
6. Set speed, continuous play, timer/extend/cancel, seek and bookmark. Check
   invalid/empty cases. Verify sleep-timer order in the guide's bedtime example.
7. Search a public directory show, choose it, play newest/oldest, queue next/end;
   verify no implicit following. Test a category and an offline feed failure.
8. Cancel Clear Entire Queue confirmation; ensure nothing changes. Only confirm
   against a disposable test Queue.

No TestFlight distribution. Do not merge until phone acceptance and CI pass.
