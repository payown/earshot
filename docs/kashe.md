# Kashe — Earshot's Ongoing Story

This file is the living record of Kashe's story. It grows with every Earshot release.

---

## Maintenance contract (read before writing or shipping any chapter)

**This file is the single source of truth for Kashe's story.** The memory note
`project_kashe_story` is only a pointer to this file plus short, in-flight working
notes. If the two ever disagree, this file wins.

Every Kashe chapter is only "shipped" once it is written into this file. The
chapter is not done when it goes out in TestFlight notes, it is done when it lives
here. To prevent drift:

1. **Write the chapter into this file as part of shipping it.** When you draft a
   new chapter for a TestFlight build, add the full chapter (heading, build
   number, italic intro, prose, and "What to test") to "The story" section below
   in the same change that deploys the build, not later from memory.
2. **Update "Details established so far"** above with any new facts the chapter
   revealed about Kashe, so future chapters stay consistent.
3. **The chapter number and build number must match what actually deployed.**
   If they diverged (pubspec vs App Store Connect), note the real numbers.
4. **Every chapter is 2500 characters or fewer.** That covers the whole chapter
   (the "What to test" section plus the story). The full chapter is the text that
   ships to TestFlight as the `--notes` payload, so there is no separate condensed
   version. Verify before shipping with `wc -m` on the chapter text; if it is over
   2500, tighten and re-count before deploying.
5. **Do not leave a chapter only in a memory note or only in App Store Connect.**
   Those are not the record. This file is.
6. The `earshot-kashe` agent and the TestFlight story protocol both treat this
   write-back as a required, non-skippable step.

---

## Prompt for Claude (web or any session)

Use this prompt to continue the story, generate social content, or write a Substack post.

```
You are helping write content for Earshot, an accessibility-first podcast player for iOS built by Michael Babcock at Payown Media. Earshot is free, open source (MIT), and built specifically for the blind and low vision community. It has a deep connection to the ACB (American Council of the Blind) and the BITS community.

Earshot's TestFlight release notes tell an ongoing story through a recurring character named Kashe. Each build ships a new chapter. The story has no fixed schedule -- it follows the release cadence.

## Voice and style

Write in Michael's voice:
- Direct, conversational, friendly
- Short paragraphs
- No em dashes
- No corporate words (no "instrumental," "crucial," "game changer," "fulfilling," "seamless," "robust")
- Contractions are fine
- First person where appropriate

## Kashe's character

Kashe is a real-feeling person, not a symbol. Her blindness is part of her life, not what defines her.

- **Name:** Kashe
- **Work:** Hands-on, like home healthcare -- visiting clients, always moving between places
- **Creative side:** Makes things, plays something, or writes. Personal, not public.
- **Listens to podcasts:** Background listener. Always on. Podcasts fill the drives, the space between clients, the time her hands are busy doing something else.
- **Personality:** Warm but direct. Quietly funny -- the joke lands before you realize she made one. Independent to a fault -- she'll struggle with something alone for three days before asking for help. People in her community come to her with tech questions. She helps them and then deals with her own problems solo.
- **Technology:** Competent and a little impatient. Skeptical by default. She's been burned by apps that promised a lot and delivered nothing. She doesn't say so out loud. She just stops using them.
- **Friend:** Renata -- the one who mentioned Earshot to Kashe in passing. Renata's connection to the app is how Kashe found it.

## Rules for writing Kashe

- She doesn't know she's in a story. She's just a person.
- Reveal details about her life gradually. Don't dump backstory. Let it surface.
- Her relationship with Earshot is earned, not instant. She's skeptical. Trust builds slowly.
- Every chapter that corresponds to a build ends with a plain-language "What to test" section.
- The story breathes with the product. No forced cadence or artificial drama.
- Keep new details consistent with what's already been established (see chapters below).

## Details established so far

- She has too many podcast subscriptions and knows it
- She was quietly done with her previous app for two months before switching
- Renata mentioned Earshot in passing during a phone call
- Kashe said uh-huh and almost didn't follow up
- She sat with the TestFlight link for a day before downloading it
- She reports problems reluctantly -- drafts messages, deletes them, sends
  them later (Chapter 4); but when two things break at once, she tells
  Renata that same night (Chapter 7)
- She has a regular client visit out past cell signal, and downloads
  episodes the night before for that drive (Chapter 5)
- Renata is her channel for feedback about Earshot -- nephew built it (or is
  connected to it)
- Chapter 9 is the first time Kashe sends Renata a thank-you instead of a
  complaint or bug report -- a small sign of trust building
- Kashe has a small speaker on her windowsill, given to her by a client's
  family last year, never set up until Chapter 10
- Chapter 10 (AirPlay) is a first pass / early feature -- framed as something
  testers should poke at and report roughness on, not a finished feature
- Kashe started using "Group by podcast" on her queue once Earshot opened
  straight to it; she works around bugs herself rather than report them
  (Chapter 11)
- She sends a whole long-form show to the bottom of the queue for the day
  (Chapter 12)
- Kashe keeps a mental "look that up later" list from things hosts mention
  mid-episode -- usually never gets to it (Chapter 13)
- Her work means moving mobility equipment: wrestling a wheelchair into her
  trunk, blood pressure cuffs, seatbelts; she pauses constantly, both hands
  busy (Chapter 14)
- The woman on her Tuesday route switched to Earshot and Kashe helped her
  bring her library over via OPML; Kashe is the tech helper in her circle and
  now recommends Earshot "without the asterisk" (Chapter 14)
- Trust arc keeps speeding up: by Chapter 16 she reports a bug the same
  afternoon, measuring it against the Chapter 4 wound but staying instead of
  leaving
- She has a small ~weekly show (two people talking) she "keeps quiet about";
  it's the one she personally lost to a bug (Chapters 17, 19)
- She uses the spoken inbox preview to triage what to play, and it changed a
  decision (Chapter 17)
- Tight morning margin: coffee, queue check, out the door before the first
  client; she normalizes small friction and doesn't report what merely
  "works" (Chapters 18, 21)
- She has a thrice-daily news show; only the latest matters by the time she's
  driving -- the driver for per-show inbox limits, which she tunes by hand
  rather than with a blanket default (Chapter 19)
- She listens at night and drifts off; "Stop after this episode" exists
  because the queue used to roll on or jump to the top while she slept
  (Chapters 19, 20)
- She kept a second app for ~2 years just to export episodes as files (for
  someone who won't install a podcast app); she deletes it once Earshot can
  export files itself -- a trust milestone echoing leaving her old app in
  Chapter 1 (Chapter 20)
- The bottom tab bar is what she uses most, dozens of times a day, glanceless;
  she'd normalized its verbose VoiceOver announcement like a rattle in the car
  (Chapter 21)
- She has a cousin (whose wedding she attended) and a great-aunt; at the wedding
  she drank at the open bar and danced with a tall, cute stranger despite "not
  dancing" -- first time we see her fully off-duty and a little reckless
  (Chapter 22)
- The Flutter-to-SwiftUI rewrite is now canon in her world: she noticed the app
  got rebuilt underneath her ("It was both"); Renata's nephew rebuilt it
  (Chapter 22)
- After the wedding her data was gone on first launch (empty inbox/library) and
  came back on the next launch with order, inbox, and saved position intact; she
  told Renata "I'm choosing to be impressed" (Chapter 22)
- She was the one who originally flagged the confusing "Play or Pause Playing"
  play/pause label to Renata, months before it got fixed (Chapter 22)
- She now sees the inbox count on the Inbox tab itself, not just the heading, so
  she can tell what's waiting from the tab bar before opening it (Chapter 22)
- On the build-119 upgrade her data held (shows, queue, and her saved place all
  intact, no empty-shelf morning like the wedding); she found the new
  Settings > Data "Import older data" row (status plus on-demand re-import) and
  valued having a recovery door she controls rather than waiting in the dark
  (Chapter 23)
- Kashe finally moved her own years-old backlog into Earshot via OPML from the
  share sheet; for once the import was the easy part (clean progress screen with
  a running count, no VoiceOver flood), and the inbox already had the most recent
  few episodes of each imported show waiting, so she had something to play right
  away instead of an empty hallway after a big import (Chapter 24)
- Kashe prefers the word "Follow" over "Subscribe" for what she does with shows:
  keeping an ear out, not signing a contract (Chapter 24)
- Kashe had been manually re-enabling "Group by podcast" on nearly every cold
  launch because the setting never persisted, and folded it into her morning
  routine rather than report it; this build makes the grouping choice stick
  across navigation and relaunch (Chapter 25)
- Now that grouping holds, Kashe runs the queue from the show headings; the
  per-group heading actions in the VoiceOver rotor gained Play Group, Sort
  Newest First, Sort Oldest First, and Shuffle Group, and the old standalone
  "Play group" button is gone (sort/shuffle reorder and announce without
  starting audio; only Play Group starts playback). She sorts her thrice-daily
  news show newest first, keeps her long interview show oldest first, and
  shuffles a backlog show she dips into with no plan (Chapter 25)
- Settings now has an Auto-advance section with two toggles, both default ON
  (existing behavior): "Continue after episode ends" (off = stop after every
  episode) and "Continue after group ends" (off = stop when a show's queued
  episodes run out instead of rolling into the next show). The one-off "Stop
  after this episode" player action from Chapter 20 is separate and unchanged.
  This names the night-drift behavior from Chapters 19/20: she'd fall asleep to
  one show and wake to a different one; she leaves "after episode" on and turns
  "after group" off (Chapter 25)
- Earshot now refreshes feeds when she opens or returns to the app, so her inbox
  is current on launch instead of a day behind; she'd given up on it and assumed
  new episodes would "turn up by lunch" on their own clock (Chapter 26)
- The Inbox tab no longer announces its count a second time as a loose standalone
  number when she flicks past it toward Queue; the count is spoken once, on the
  tab itself. She'd taught herself to flick past the stray number (Chapter 26)
- The Library can now be sorted: Alphabetical (ignoring a leading The/A/An, so
  "The Archers" files under A, not T) or Last published (newest-active shows on
  top). It used to be fixed in the order shows were added, burying old follows in
  the middle of a list too long to scan; she keeps it alphabetical (Chapter 26)
- She again invokes the woman on her Tuesday route she'd helped move a library
  over (Chapter 14), who'd once asked how she ever finds anything in a list that
  long (Chapter 26). That woman is named Renata, and the move was an OPML
  subscription list (Chapter 27)
- In a grouped queue, each queued episode's VoiceOver rotor now has Move up /
  Move down that reorder it within its own show's stack only (stepping over
  other shows), and the duplicate "Remove from queue" that used to be listed
  twice is gone. Edge no-ops stay silent. The show headings gained Move Group
  Up / Move Group Down, which move a whole show as a block and return focus to
  the moved heading (Chapter 27)
- Kashe listens largely from earbuds with the phone in a pocket; the earbud /
  lock-screen skip-forward and skip-back controls now skip within the current
  episode instead of jumping to a different episode (they used to register as
  next/previous track). She'd stopped using skip and sat through ads rather
  than fight it (Chapter 27)
- An OPML subscription file now opens directly from Files into Earshot instead
  of stalling (Chapter 27)
- A VoiceOver-responsiveness tune-up with no new buttons: the inbox stopped
  re-fetching itself repeatedly during playback, the episode/queue/bookmark lists
  shed redundant per-focus accessibility work, the player scrubber stopped
  re-announcing its name every second (name said once, live time now in its
  value as elapsed of total), and podcast artwork now decodes off the main thread
  at display size so fast scrolling no longer hitches. Kashe always has audio
  playing, so she feels all of it at once; the through-line is the app no longer
  fighting VoiceOver while a show plays (Chapter 28)
- The two queue "add" actions were renamed from "Add to queue (top)" / "Add to
  queue (bottom)" to "Play next" / "Add to end of queue"; Play next now inserts
  right after the now-playing episode (front fallback when nothing relevant is
  queued). And because Kashe runs the grouped queue with "Continue after group
  ends" off (Chapter 25), an explicit Play next now overrides that group-edge
  stop for that one advance, so the episode she points at actually plays next
  even across shows; normal auto-advance at group edges still stops (Chapter 29)
- Every value adjuster (playback speed, sleep timer, skip intervals, per-podcast
  limits, and the inbox/download/history settings) is now a VoiceOver Adjustable
  control: flick up to increase, flick down to decrease, value spoken instantly.
  The in-player speed badge changes speed in place by flicking (the full sheet is
  the "Open speed options" rotor action); the sleep timer flicks from Off up
  through the presets to End of episode. Reinforces Kashe operating the app "by
  feel," one-handed from a pocket (Chapter 27), and her night sleep-timer habit
  (Chapters 19/20). She fidgets with speed: ~1.5 for dense shows, ~1.1 for fast
  talkers (Chapter 30)
- Each podcast's episode list now has an All / Unheard filter at the top
  (segmented control); Unheard hides finished episodes, All shows everything,
  defaults to Unheard and is remembered per show, and VoiceOver announces the
  selection plus the new count. And a "Play oldest first" binge action plays a
  show's episodes oldest to newest and keeps rolling through that show instead
  of jumping to a random inbox episode at the end; it respects the active
  All/Unheard filter and leaves the existing queue untouched. Kashe uses it to
  start a show she wants from the very beginning, in order, having given up
  before and listened newest-first; she leaves the filter on Unheard so the
  show stays just what's left as she works through it (Chapter 31)
- Every one of the five tabs (Inbox, Queue, Library, Downloads, Settings) now
  reads its screen title FIRST as a proper heading before any toolbar/options
  button, instead of handing her "Queue options" and the like ahead of the
  name; the Now Playing mini-player bar above the tabs now reads as a single
  group labeled "Now Playing" instead of scattered loose controls. She'd
  normalized waiting a beat for the title and skipping whatever came first
  (Chapter 32)
- The Queue tab now carries an episode count and red badge and announces
  "Queue, N items," matching the Inbox tab's count (Chapter 22), so she can
  tell how deep the queue is from the tab bar without opening it; no stray
  extra number when flicking past (Chapter 32)
- Her Default launch screen choice (Queue, set back in Chapter 9) had quietly
  regressed to always opening on the Inbox; she'd been flicking over to the
  Queue on every cold launch without thinking. This build honors the chosen
  launch tab again (Chapter 33)
- Episode rows now show time on them: "X min left" for an episode she's
  started, or the full length for one she hasn't, in Queue, Inbox, and
  Library. She reads it to plan what fits before a stop (Chapter 33)
- VoiceOver now speaks a brief one-sentence summary of each episode as she
  navigates the rows (after title, show, and time), broader than the
  inbox-only spoken preview from Chapter 17 (Chapter 33)
- The per-podcast inbox cap (Chapter 19) now also caps the Queue: a show
  capped in its Inbox settings (e.g. her thrice-daily news show kept to 1) no
  longer piles up unbounded in the Queue; the oldest auto-queued episodes are
  evicted to keep only the newest few. It never evicts the now-playing
  episode or anything she sent with Play next (Chapter 29) (Chapter 33)
- In Search, Activating a result now opens a preview (description plus recent
  episodes) instead of following on the spot, and Follow is a real toggle that
  flips to Unfollow; this lets Kashe look before she leaps instead of every tap
  adding another show to her pile (the over-subscribing thread, Chapters 1, 8,
  19). Search results announce "result N of M," speak a count when they settle,
  and expose the native iOS VoiceOver vertical scroll bar. She can now Unfollow
  a show straight from an Inbox row swipe (with a confirm), removing the show
  and its episodes without a trip to settings, which finally makes the pruning
  she's put off for years easy. Renata again mentions a show in passing, the way
  she did in Chapter 8. Queue rows now show "X min left" / full length too,
  completing the Chapter 33 time-remaining feature that had missed the Queue
  (Chapter 34)
- The player now surfaces chapters on chaptered shows: the current chapter shows
  under the title and updates as it plays, with Previous chapter / Next chapter
  controls (VoiceOver rotor actions on the artwork that announce the chapter
  name). Activating the chapter name opens a chapter list where each chapter is
  one VoiceOver stop; double-tap plays from there. A rotor action "Skip this
  chapter" / "Include this chapter" deselects a chapter so playback steps over
  it; all chapters play by default and skip choices last only the listening
  session ("It forgets by morning"). Kashe uses it on her long oldest-first
  interview show (Chapter 25) to skip the recurring sponsor/listener-mail
  housekeeping block she'd spent years thumbing past by feel in the dark, and to
  jump straight to the guest. Search results also now count correctly ("result 1
  of N, 2 of N, 3 of N"), with duplicate listings of the same show removed and an
  honest count, finishing the Chapter 34 search numbering (Chapter 35)
- The chapter controls from Chapter 35 worked, but on the MP3 shows Kashe
  actually listens to (chaptered by tools like Auphonic), the list came up
  empty ("No chapters") because AVFoundation doesn't read ID3 chapters out of
  MP3s; she'd quietly filed it as the show not doing chapters or the feature
  only half-working. This build parses embedded ID3 chapters itself, even
  while streaming (reading just the tag, not the whole file) and from the
  downloaded file once saved, so chapters finally appear on her years-old tech
  show. Reinforces her default skepticism ("a thing that works in the demo and
  not in your hands") landing in trust when it actually delivers (Chapter 36)
- The player now shows tap targets for chapter navigation: a Previous chapter
  button to the LEFT of the chapter name and a Next chapter button to the RIGHT,
  on by default. A new Settings > Playback > "Chapter navigation buttons" toggle
  hides them for a cleaner player or for someone who prefers the artwork rotor
  flick; hiding them never removes chapter navigation (the artwork rotor
  Previous/Next chapter actions still work either way). Kashe had been working
  the chapters from Chapters 35/36 by the rotor (find the action, fire it, two
  steps); she tries the buttons, likes the fixed spot, and leaves them on while
  keeping the rotor as the other option. A beat of the app giving her both and
  letting her choose, in character with her independence (Chapter 37)
- From a search-result podcast preview (the look-before-you-leap screen from
  Chapter 34) she can now tap an episode and stream it on the spot, no Follow
  first, nothing added to her library or queue. This completes the order she's
  wanted on the over-following thread (Chapters 1, 8, 19, 34): look, then
  listen, then decide; she played ten minutes of one, decided no, closed it,
  nothing to undo. And feed descriptions that used to render raw HTML (literal
  tags and bracket-clutter where the words should be) now read as clean plain
  text everywhere a description shows, including for VoiceOver; she'd taught
  herself to read around the tag soup (Chapter 38)
- Not every drive is out past signal (Chapter 5); most are just spotty, one bar,
  and when she streams on those weak stretches a buffering dip used to go silent
  and stay silent until she found the phone and pressed play again, both hands
  busy (a wheelchair half into the trunk, Chapter 14). This build makes streaming
  recover on its own after a dip (a manual pause stays paused), and the phone runs
  cooler through a rough-connection stretch instead of the warm brick it became by
  the far end of the route (distinct from the Chapter 15 runaway-loop warmth). She
  notices the recovery once, then stops noticing it (Chapter 39)
- Kashe's Quick Actions had a fixed order she'd set once and never changed, because
  reordering meant dragging a row to a new spot and "a drag you can't see is a drag
  you can't do," so "Play now" sat third or fourth down and she reached past the
  rest. This build puts Move to top / up / down / bottom in the VoiceOver Actions
  rotor on each Quick Actions settings row, so she reorders by flick instead of
  drag; she moves "Play now" to the top so one flick fires her most-used action
  (Chapter 39)
- Inbox and Downloads rows now speak the podcast's name right after the episode
  title (matching the Queue), with the show name as a small caption under the
  title for sighted users. Half her inbox titles episodes like paperwork
  ("Episode 214," "March mailbag"), and she used to sit on a row and guess, or
  open it just to learn whose voice she was about to get (Chapter 40)
- The privacy screen she once audited (Chapter 6) got shorter and truer: the two
  old crash-report and analytics toggles are gone and the copy in onboarding and
  Settings plainly says Earshot collects no data. The rebuilt app (Chapter 22)
  had never been sending anything; the words just caught up. "Fewer promises,
  all of them true" is her kind of screen (Chapter 40)
- Settings has an Appearance section: theme override (Follow System default,
  Light, Dark, High Contrast Light, High Contrast Dark), accent color, and
  layout density (Comfortable or Compact; Compact never shrinks touch targets).
  Kashe picks nothing for herself but files it as an answer for the folks on her
  routes who still read the screen, big and bright (Chapter 40)
- The version is 1.0.0 now, the App Store release candidate line; she recalls
  Renata's "still rough around the edges" from the very first phone call and
  just notices, no text to anyone (Chapter 40)
- The Actions rotor on episode rows had been reading her Quick Actions in
  reverse: after the Chapter 39 reorder put Play now on top, the rotor handed
  it back last, so she reversed her whole Settings list on purpose so the
  rotor came out right side up. That workaround is the unstated cost behind
  Chapter 39's "one flick does the thing she does most." She never reported
  it. This build reads the order as written; her upside-down list came out
  backwards on the first flick, she straightened it to plain order for the
  first time, and it held (Chapter 41)
- The duplicate "Mark as played" that had leaked into the rotor from the
  sighted swipe is gone; said once, like the doubled Remove fix in Chapter 27
  (Chapter 41)
- "Unfollow this podcast" is now the ninth Quick Action, reorderable like the
  rest, with a confirmation dialog, available on Inbox, Downloads, and a
  show's episode list rows (never on search preview episodes); the sighted
  swipe still works with VoiceOver off. She placed it at the bottom of her
  list: a thing that removes a whole show should be a reach, not a reflex
  (Chapter 41)

## What you can generate

- The next chapter of the story (tied to a specific build's changes)
- A Substack post expanding on a chapter with more context about the feature
- A social media post (short, in Michael's voice, hinting at the story without spoiling it)
- A retrospective post covering multiple chapters as the story grows

When writing a new chapter tied to a build, only write about user-facing changes -- things Kashe would actually notice. Security fixes, dependency updates, and CI changes don't appear in her story.
```

---

## The story

### Chapter 1 — Before Earshot

*Published with the first TestFlight invite*

Kashe almost didn't catch it.

She was on the phone with Renata, half-listening, pulling her coat on to get to her next client. Renata was talking about something her nephew had built. A podcast app. Accessibility-first, she said, whatever that means. Free. Open source. Still rough around the edges.

Kashe said uh-huh the way you do when you're already thinking about the next thing.

She thought about it again that night. She'd been quietly done with her current app for two months. It wasn't broken exactly. It just made her feel like an afterthought. Little things. The kind of things that add up until you stop trusting something.

She found the TestFlight link. She sat with it for a day.

Then she downloaded it.

---

### Chapter 2 — Build 86

*Kashe downloaded Earshot a few days ago. She has too many subscriptions and not enough patience for apps that don't work. You'll hear more about her.*

She'd been using it long enough to stop trusting the Delete button.

It was supposed to clear an episode from her inbox. Sometimes it did. Sometimes it didn't. She'd tap it, the episode would stay, she'd tap it again. And every time, before any of that, a dialog asking if she was sure. She was always sure. That was never the question.

This build fixes that. Delete is gone. The new action is Clear from inbox, no confirmation, and it doesn't touch the audio file -- it just tells Earshot she's done with it. Works the first time. If she wants the episode marked as played at the same time, there's a setting for that now in Inbox settings.

One other thing. Earshot now checks links in show notes before opening them. Only http, https, and mailto get through. Podcasters are generally trustworthy. Not always.

**What to test:**

Open your inbox. Use the actions menu on any episode and tap Clear from inbox. It should disappear immediately, no confirmation, first try, every time. Then go to Settings, Inbox, and turn on "Mark as played when clearing from inbox." Try it again and check that the episode shows as played in your library afterward.

If anything's off, shake your phone to send a bug report.

---

### Chapter 3 — Build 93

*Kashe has been using Earshot for a few weeks now. She's cautiously warming up to it.*

Kashe noticed it first thing in the morning.

She opened Earshot before coffee, phone still on the nightstand. VoiceOver was doing its thing -- time, battery, the usual. Then she switched to Earshot and nothing moved. VoiceOver had parked itself somewhere outside the app and wasn't coming back. Battery percentage. Time again. She swiped right and hit nothing.

She killed it and reopened it. Same thing for a second, then it snapped in and she was in the inbox. Empty. Checking. The usual two-minute wait.

She'd been meaning to say something.

This build fixes the launch focus issue. When you open Earshot with VoiceOver on, focus lands where it should instead of getting stuck on the status bar. And the wait for the inbox to populate is significantly shorter -- the app now fetches your feeds in parallel instead of one at a time. If you follow a lot of shows, you'll feel the difference.

There's also a "Checking for new episodes" state now while the refresh runs, so you know what's happening instead of staring at an empty screen. And if the Library screen ever hits an error, there's a real Retry button. Pull to refresh wasn't working in that state before.

Kashe got through half her morning prep before the inbox was done loading. That used to be the whole morning.

**What to test:**

Open Earshot with VoiceOver on. Focus should land on the inbox or navigation bar right away -- not the status bar. If you were experiencing a launch hang or delay, that should be gone.

Check your inbox. If it's refreshing, you'll see "Checking for new episodes" instead of a blank screen. Your episodes should show up much faster than before, especially if you follow a lot of shows.

If the Library screen ever shows an error, try pulling to refresh or tapping the Retry button. Both should work now.

---

### Chapter 4 — Build 94

*Kashe's been running Earshot through real days now. Then something breaks that actually scares her.*

She was switching between episodes in her queue, tapping the next one up while she grabbed her bag. The app froze. Not slow. Frozen. She force-quit and reopened it, and the episode she'd been thirty minutes into, the one she actually cared about, was sitting in her history marked played. Untouched. Done. Gone.

She knew exactly what that meant. An app deciding things for you. That's the thing she left her last app over.

She started typing a message to Renata. Got halfway through, deleted it, put the phone away. Sent it the next morning instead.

This build fixes both things. Tapping the next episode in your queue no longer crashes. And played status is honest now: nothing gets marked played until you've actually finished it. If the app crashes mid-episode, it picks back up exactly where you left off, not at the end.

**What to test:**

In your queue, tap through to the next episode a few times in a row. It should switch cleanly, no freeze.

Start an episode, let it play for a bit, then force-quit the app. Reopen it. The episode should still show as in progress, not played, and should resume near where you left off.

---

### Chapter 5 — Build 95

*A quieter build this time. Nothing was on fire.*

Kashe has a client out past where her phone gets any signal at all. She'd gotten in the habit of downloading a few episodes the night before so she'd have something for the drive. Except it never quite worked. Earshot would still try to stream first, stall out reaching for a connection that wasn't there, and she'd drive in silence.

This build plays downloaded episodes straight from the file on your phone. No reaching for a connection first. If it's downloaded, it just plays.

She also noticed something smaller while flicking through her queue with VoiceOver. The actions feel the same now wherever she is. Same flick-down options, same "more actions" sheet, whether she's in her inbox, her queue, or browsing a show's episode list. Before, each screen had its own slightly different version of the same menu, and she'd had to relearn it each time.

Nothing to report to Renata this time. Just things working the way they should.

**What to test:**

Download an episode, then turn on airplane mode (or go somewhere with no signal) and play it. It should start instantly, no buffering or stalling.

Compare the actions menu (flick down, or the "more actions" button) in your inbox, your queue, and a show's episode list. They should offer the same actions in the same order everywhere.

---

### Chapter 6 — Build 96

*Earlier, Kashe almost lost an episode to a crash. This build, she goes looking for what Earshot actually knows about her.*

After the queue scare a few builds back, Kashe found herself thinking about it again. Not the bug exactly, but what the app had been doing behind the scenes while it crashed. She went into Settings, into Privacy & History, somewhere she'd never had a reason to look before.

Two toggles sat there, crash reports and anonymous analytics, both on by default. Each had a plain description of what it actually sent. Crash reports: "never contains your podcasts or listening history." Analytics: "never contains search queries, episode titles, or personal data." She turned the analytics one off, just to see. A note said it would take effect next time she restarted Earshot. She force-quit, reopened, checked. It had stuck.

She turned it back on. The trade seemed fair, and now she'd actually checked instead of assuming.

This is also the first build where crash reports go somewhere real. If something like the queue crash from a few builds back happens again, Earshot can tell us about it automatically, device and OS info only, never podcasts or listening history.

**What to test:**

Open Settings, then Privacy & History. Read through the crash reports and analytics descriptions.

Turn one off, force-quit and reopen the app, and confirm it stayed off.

If you're comfortable, leave crash reporting on. It helps catch bugs like the queue crash automatically.

---

### Chapter 7 — Build 97

*Kashe just turned crash reporting back on. Then two things broke at once.*

She updated right after that last build, crash reporting freshly back on, feeling good about it. Earshot got stuck on its loading screen. She waited. Force-quit, reopened, still stuck, now with "Something went wrong" and nothing to do about it. No retry, no reset, nothing.

She had a route that needed her queue that morning. So she did the thing she really didn't want to do: deleted the app and reinstalled it. Subscriptions, queue, listening history, all of it, gone.

Re-subscribing to her shows, she hit a second thing. Opening a show's page, VoiceOver said nothing, no show name, nothing to tell her where she'd landed. And swiping back from the Back button put her on a silent, unlabeled stop before anything else.

This time she didn't wait three days. She texted Renata that night: tell your nephew two things broke.

This build fixes the update problem at the root, so the kind of database update that got stuck before now runs safely. And if something ever does go wrong, there's a "Reset local data" option so you're not stuck staring at an error with no way out. Podcast pages now announce the show's name as soon as they open, with no silent stop near the top, plus a new "Refresh podcast" button if you want to manually check for new episodes.

**What to test:**

If you update from an older build, the app should open normally, no stuck loading screen.

Open a podcast's page. VoiceOver should announce the show's name right away, with no silent or unlabeled stop near the top.

Look for a "Refresh podcast" button on the podcast page and try it.

You shouldn't need this, but if Earshot ever gets stuck again, check Settings for a "Reset local data" option.

---

### Chapter 8 — Build 99

*Kashe's subscription list has gotten a little out of hand. This build gives her a faster way to check it.*

Renata mentioned a new show she'd started, the kind of casual "you should check this out" that usually means another subscription Kashe forgets about within a week. Except this time Kashe wanted to check something first: had she already subscribed to this one and forgotten, like half the others?

Her All Podcasts list is long. Long enough that finding one show meant dragging a finger down a list for a while, swipe after swipe, hoping she'd recognize the name when it came around.

This build adds an alphabet index along the edge of All Podcasts. One VoiceOver stop. Swipe up or down and it moves letter by letter, announcing the letter and how many shows start with it, jumping the list to match.

She found the show. Already subscribed, months ago, completely forgotten.

She didn't message Renata about it. But for the first time, she thought about actually going through that list and cleaning it up. Maybe next week.

**What to test:**

Open All Podcasts with VoiceOver on. Find the alphabet index along the edge, it should be a single stop, not one per letter.

Swipe up and down on it. Each swipe should announce a letter and how many podcasts start with it, and the list should scroll to match.

Swipe past Z or back past A. It should announce that you've hit the end instead of going silent.

With VoiceOver off, tapping a letter directly should still jump the list to that letter.

---

### Chapter 9 — Build 100

*Kashe's routine hasn't changed. Earshot has, just a little.*

Most mornings, Kashe's routine is the same. Queue up the night before, headphones in, out the door. But every time she opened Earshot cold, it landed her on her library, the full list of shows, and she had to tap over to her queue. One extra tap, several times a day, every day.

After the alphabet index worked exactly the way she'd hoped, she actually messaged Renata back this time. Not a complaint. A thank you, and a small ask: tell your nephew it's working great. One more thing though, can it just open to my queue?

This build adds that. Settings now has a General section with a "Default launch screen" choice: Inbox, Queue, Library, or Downloads. Kashe picked Queue. Now every cold launch drops her right where she left off.

While she was in Settings, she noticed something new near the bottom: Send Feedback. She tapped it on a whim. Her email app opened with the subject already filled in, Earshot Feedback, with the version and build number right there. She didn't write anything this time. Just good to know it's there, for when she needs it.

**What to test:**

Go to Settings, then General, then "Default launch screen." Pick something other than Library, like Queue or Inbox. Force-quit Earshot completely, then reopen it. It should open directly to the screen you picked.

Go to Settings, scroll to the bottom, and tap Send Feedback. Your email app should open addressed to michael@payown.media with a subject line like "Earshot Feedback (v0.1.0+100)," matching the version in Settings, Version. If you don't have an email app set up, Earshot should show a message with the email address instead.

---

### Chapter 10 — Build 101

*Kashe's evenings are hers. Tonight, a new icon shows up in the player.*

Most nights her hands are busy with something and the earbuds keep tugging loose every time she leans over. She'd been meaning to try the little speaker on the windowsill, the one a client's family gave her last year that she never got around to setting up.

She opened the player and there was a new icon next to Close, top right. She swiped to it. "AirPlay." She'd heard the word before, never really known what it did. Double-tapped.

A list popped up. Her speaker was on it. She picked it.

The podcast kept playing, just from across the room now instead of her ears. She set the phone down and let it run while she worked.

She's not sure yet if this is something she'll use every night or forget about in a week. But it worked, first try, which is more than she expected.

This is a first pass at AirPlay support. If something about it feels off, routing, audio quality, the controls while it's connected, that's exactly the kind of thing worth flagging now.

**What to test:**

Open the player and look for a new AirPlay icon next to Close, top right (iOS only, it won't show on Android). With VoiceOver on, swipe to it, it should announce "AirPlay," and double-tap to open the system AirPlay picker. Pick a speaker or AirPlay-capable TV and confirm playback switches over cleanly.

While connected, check that Now Playing info, lock screen controls, and the sleep timer all keep working. Switch back to your phone's speaker mid-episode and confirm it's smooth, no stall or crash.

This is the first pass at AirPlay, so if anything feels rough, hard to find with VoiceOver, audio cutting out, controls not responding while connected, let us know.

---

### Chapter 11 — Build 102

*Now that Earshot opens straight to her queue, Kashe's paying more attention to how it's put together.*

Since the app started opening to her queue, Kashe had been thinking about it as a real list, something to organize, not just whatever landed there. She turned on "Group by podcast." It keeps each show's episodes together, which makes it easier to plan: knock out the short news shows first, save the long interview for the drive with no signal.

One evening she wanted to move a shorter episode ahead of a longer one from the same show, so she'd finish it before her next stop. She flicked to "Move up" on the actions rotor. Nothing happened. Tried again. Still nothing.

So she moved it to the very top of the whole queue instead. That worked, but now it was ahead of everything, not just the other episode from its show. She nudged it back down a couple of times, trying to land it where she wanted. Closer. Not quite.

She didn't message Renata about it. It felt like a fiddly thing she'd just work around. A few episodes deep into working around it, she gave up and listened in whatever order it landed.

This build fixes "Move up" and "Move down" so they move an episode within its own show's group, not the whole queue. Same actions, same rotor flicks. They just go where she expects now.

**What to test:**

Turn on "Group by podcast" on the Queue screen. With a queue that has episodes from at least two shows mixed together, pick a middle episode in one show's group and use the actions rotor to "Move up" or "Move down."

Confirm it moves within that show's group, the announcement should give its new position within the group, and it doesn't jump over to a different show's spot.

---

### Chapter 12 — Build 103

*Kashe's gotten comfortable with "Group by podcast." This build smooths out moving around it.*

Grouping her queue by show had become the way Kashe ran her mornings. But navigating it by heading with VoiceOver, jumping show to show, sometimes lost her. Expand one group and the headers below it would slip out of reach, like they weren't there anymore.

And moving a whole show up or down the queue meant the same per-episode nudging from a few builds back, just more of it. She wanted to send a whole show to the bottom for the day and couldn't, not in one move.

This build fixes the heading navigation so expanding a group no longer hides the headers under it. And it adds group-level moves: on each show's header, the actions rotor now has "Move group to top," "up," "down," and "to bottom." The group counterpart to moving a single episode.

She sent her long-form show to the bottom with one flick and got on with her day.

**What to test:**

Turn on "Group by podcast" with episodes from a few shows. Navigate by heading with VoiceOver and expand a group, the headers below it should stay reachable, not disappear.

On a show's group header, open the actions rotor. You should find "Move group to top," "Move group up," "Move group down," and "Move group to bottom." Try each and confirm the whole group moves as a unit.

---

### Chapter 13 — Build 104

*Kashe's queue has gotten longer, and so has her list of "look that up later."*

A host mentioned a tool partway through an episode, said the link was in the show notes, and Kashe filed it away the way she files most things: for later, which usually means never.

This time she remembered. She found the episode in her queue, opened the player, and tapped Show notes. Before, nothing told her it had worked, just whatever was in there, waiting to be found by accident. This time VoiceOver said it plainly. "Show notes, expanded." Then "Show notes expanded," again, just to be sure.

She swiped through. Found the link, tapped it, her browser opened. Good.

Getting back was the part she'd dreaded. Last time she'd had to swipe backward through everything to find the toggle again. This time, past the last line of text, there was a button: "Collapse show notes." She tapped it. "Show notes collapsed." Done. Back to the episode controls, right where she needed to be.

She didn't think about it again. Which is the point.

**What to test:**

Open the player for an episode with show notes and activate "Show notes." VoiceOver should announce "Show notes expanded" and land you near the top of the notes, not back up at "Close player."

Swipe forward through the show notes. After the text, you should find a "Collapse show notes" button. Activate it - VoiceOver should announce "Show notes collapsed" and take you back to the player controls.

---

### Chapter 14 — Build 105

*Kashe's hands are always busy. This build meets her there, and helps a friend come over from another app.*

The thing Kashe does most with Earshot isn't tapping a button. It's pausing. A client's blood pressure cuff, a seatbelt, wrestling a wheelchair into her trunk, every one of those needs both hands, and every one of those is a moment she wants the audio to stop without hunting for a control.

This build adds magic tap. A two-finger double-tap anywhere in the app toggles play and pause and tells her which it did, "Playing," "Paused," or "Nothing playing." No need to be on the player screen. No need to find a button. It took her about a day to stop reaching for the button out of habit.

The other half of this build came from her Tuesday route. The woman there finally switched to Earshot for real, years of shows in her old app. Kashe walked her through the export. Earshot showed up in the share sheet, she tapped it, and a whole library moved over in under a minute, this many added, the rest already there.

Kashe's started recommending Earshot without the asterisk she used to add.

**What to test:**

Start something playing. Two-finger double-tap anywhere in the app, it should toggle play and pause and announce "Playing" or "Paused." With nothing playing, it should say "Nothing playing."

If you have an OPML file from another podcast app, open it and choose Earshot from the share sheet. Your shows should import, with a count of how many were added versus already subscribed.

---

### Chapter 15 — Build 106

*A handful of fixes this time. The phone getting warm, a Done button that stranded people, and a couple of smaller things Kashe had stopped noticing.*

The woman on Kashe's Tuesday route texted a few days after her import. Everything came over fine, but she'd gotten stuck in a settings screen and couldn't get back out, mentioned it twice. Kashe tried it herself, imported a backup from Files, tapped Done, and landed right back in a settings screen instead of her library. She texted back one word: fixed, once this build went out.

This build sorts out a cluster of things:

The app could get warm and even crash about a minute into an episode when nothing was queued up next. That's gone now, a runaway loop in the background got shut off, and future crashes like it will actually get reported.

The Done button after importing now drops you on your real home screen, the launch screen you picked, instead of stranding you in Settings.

Magic tap finally says "Playing" when you resume, it had been silent on resume since it landed, and Kashe had just assumed that was how it worked.

And clearing your queue now returns everything to your inbox the next morning the way it should, nothing quietly lost.

She noticed the phone wasn't getting warm on her route anymore. She couldn't say exactly when that started. It just wasn't a thing anymore.

**What to test:**

Play an episode with nothing queued after it and let it run past the one-minute mark, the app should stay cool and stable, no crash.

Import an OPML file, then tap Done, you should land on your default home screen, not a settings screen.

Resume a paused episode with magic tap (two-finger double-tap), it should say "Playing." Clear your queue and check that those episodes return to your inbox.

---

### Chapter 16 — Build 107

*The one thing that almost made Kashe leave, back at the start, happens again. This time she stays.*

Kashe updated between clients, sitting in her car, a Tuesday. Reopened the app and the player was empty. She found the episode in her inbox, hit play, and it started over from zero. About thirty minutes of listening, gone.

This was the exact thing from way back that she'd almost left over. An app losing her place, deciding things for her.

But she didn't delete it this time. She texted Renata that afternoon, faster than she used to report anything: lost my spot after the update, thirty minutes gone, tell your nephew.

This build fixes it at the root. An episode you're in the middle of keeps its place across an update, it won't come back marked played and reset to the start. A couple of related things came along with it: finishing the last item in your queue now stops instead of looping back to the beginning of it, and an alarm going off mid-episode pauses and then resumes when you dismiss it, while pulling your earbuds stops the audio instead of blasting it out the speaker.

When it's done, it's done. When you're interrupted, it waits for you.

**What to test:**

Start an episode, get a few minutes in, then update or fully restart the app. The episode should still be your now playing, still in progress, and resume near where you left off, not back at zero, not marked played.

Let the last episode in your queue finish, it should stop, not repeat from the beginning. If an alarm fires mid-episode, it should pause and resume on dismiss. Pulling your earbuds should stop playback, not switch to the speaker.

---

### Chapter 17 — Build 108

*A quiet show went quiet for weeks, and Kashe almost gave up on it. Turns out it was never the show.*

Kashe has a small show she keeps quiet about, two people talking, about once a week. It had gone silent in her inbox for weeks. She figured they'd gone on hiatus and nearly unsubscribed. Then after this update, new episodes came back, and she found a few she'd missed sitting in the show's episode list. Something on her end had quietly decided those didn't count as new.

This build fixes that at the root, one episode with a strange future date had poisoned how the app tracked what was new for that show, and there's a repair step so shows already caught by it heal themselves.

Four more things came with it:

Going through her inbox each morning, VoiceOver now reads a short line about what each episode is, after the title, show, and length, before she even opens it. She kept one she'd have skipped on the title alone.

Opening show notes now announces "Show notes" and exposes the title as a heading, so when she wants the rest, it's structured.

The plus and minus chevrons on the sleep timer are big enough to catch on the first tap now.

And removing the next episode in your queue no longer plays it anyway, pull it, it's gone.

**What to test:**

If a show stopped showing new episodes for you, check it after updating, missed episodes should return and new ones should come through normally.

In your inbox with VoiceOver, listen past the title, show, and length for a short description of each episode. Open show notes and confirm it announces "Show notes" with the title as a heading. Try the sleep timer's plus and minus buttons, they should respond on the first tap. Remove the upcoming episode from your queue and confirm it doesn't play.

---

### Chapter 18 — Build 109

*Kashe's mornings have a tight margin. This build hands a minute of it back.*

Coffee, queue check, out the door before the first client. That's the window. And for a while there's been a hitch in it: open Earshot cold and the inbox badge shows a number right away, but the list under it isn't tappable yet. She'd tap, nothing. Tap again. Wait.

She'd filed it under the price of having too many shows, the same way she files most small friction, and worked around it. Open the app, set the phone down, pour the coffee, come back to it. By then it was usually ready.

This build clears that. The inbox is usable the instant it appears, no dead first minute on a big library.

She noticed it the way you notice a sound stopping. The coffee routine still works. She just doesn't need it as a stall anymore.

**What to test:**

If you follow a lot of shows, force-quit Earshot and open it cold. The inbox should be tappable as soon as it shows up, you should be able to open the first episode right away, no dead period where taps do nothing.

---

### Chapter 19 — Build 110

*Kashe's been meaning to clean up her subscriptions for years. This build does it with her, one show at a time.*

The over-subscribing thing has been with Kashe the whole way, every show someone mentions, subscribed just to try, never cleaned up. She's joked about it, put it off, thought about it on a slow morning and let it go.

This build finally pays it off, not by deleting anything, but by letting her tell each show how much of it stays in her inbox.

She has a news show that posts three times a day. By the time she's driving, only the latest one matters. Now she can cap that show to just the latest, or set an age limit so yesterday's news doesn't greet her this morning. There's a global default too, but she left it off and tuned the noisy shows by hand. That's more her speed, hands-on, show by show, no blanket rule.

Nothing gets deleted. Trimmed episodes stay in the show's list if she wants them. And nothing she's played, started, or queued gets touched, the half-finished episode she fell asleep to is right where she left it.

Two smaller things came along. "Remove from queue" on the episode that's currently playing now finishes it and moves on cleanly. And that small weekly show she keeps quiet about re-posted a corrected episode, and this time it found its way back to her inbox instead of vanishing.

One more, caught on a real device: VoiceOver now speaks the confirmation when you save an inbox-limit setting. It used to get cut off as the picker closed.

**What to test:**

Open a show's settings and look for inbox limits, a count cap (keep just the latest few) and an age limit (drop anything older than a day or so). Set one on a show that posts a lot.

Confirm older inbox episodes for that show get trimmed, but they stay in the show's full episode list, and anything you've played, started, or queued is left alone. There's a global default in Settings if you want one. When you save a limit, VoiceOver should speak the confirmation, not cut off as the picker closes.

---

### Chapter 20 — Build 111

*Two features, one idea: the audio is hers to take, and the playback does what she says and nothing else.*

For about two years Kashe kept a second app installed for one job, pulling an episode out as a plain audio file. Download it in her podcast app, hand it off to that one, rename it from whatever-ep-number into something a person could read. She needs a file now and then for someone who won't install a podcast app, a client, someone on her route.

This build does it itself. From an episode's actions: Export audio file. Share sheet, save to Files, AirDrop it, send it to another device, already named "Show - Episode." If it isn't downloaded yet, it downloads in the background and shares when it's ready. Cellular asks once.

She deleted the two-year-old backup app that night. The same way she left her old podcast app at the very start, when something finally did the thing she'd been working around.

The other half is about her nights. She listens in bed and drifts off, and the queue used to roll on without her, some nights jumping back to the top while she slept. Now there's a one-off "Stop after this episode" in the player. Turn both Continue switches off and it stops after the current episode, full stop. And the queue shows the episode that's playing right in place, marked "Now playing," instead of pinning it to the top, so it advances to the item below it, not back to the head.

All she wanted was for it to do what she said and nothing else.

**What to test:**

On an episode, open the actions and choose Export audio file. The share sheet should open with the file named "Show - Episode," save it to Files or AirDrop it. Try it on an episode you haven't downloaded, it should download in the background and share when ready, asking once on cellular.

In the player, try "Stop after this episode" and confirm playback stops after the current one. Turn off both Continue switches and check the same. In the queue, the now-playing episode should sit in place marked "Now playing," and playback should advance to the item below it, not jump to the top.

---

### Chapter 21 — Build 112

*The thing Kashe touches most, all day long, finally gets out of her way.*

The bottom tabs, Inbox, Queue, Library, Downloads, are the part of Earshot Kashe uses more than anything else. Dozens of times a day. Between clients, at red lights, phone half out of her pocket, not looking at it.

For a long time every tap came with a mouthful: "Inbox, Tab 1 of 4, button." She'd stopped hearing it, the way you stop hearing a rattle in the car. It was just the sound the app made. She never reported it. It worked, and she'd normalized the friction.

This build cleans it up. Now it's "Inbox, 3 new." The tab she's on says "selected." No "button." No "Tab N of 4." The count spoken once, not buried in extra words.

The honest detail: VoiceOver speaks a clean label and "selected," but not the literal word "tab," that's just how iOS handles it. In practice it's faster and quieter, which is the whole point when you're hitting it all day without looking.

She didn't notice it the way you notice a new feature. She noticed it the way you notice a rattle finally gone.

**What to test:**

With VoiceOver on, move across the bottom tabs. Each should read its name and, for tabs with a count, the count spoken once, like "Inbox, 3 new." No "button," no "Tab N of 4."

The tab you're currently on should announce "selected." Moving between tabs should feel quicker and less wordy than before.

---

### Chapter 22 — Build 118

*Kashe comes home from a wedding to an empty app, decides not to panic, and gets everything back — then notices a small old annoyance has quietly been fixed too.*

What she'd leave out is the tall, cute stranger who talked her onto the dance floor "for one song," and how one song became however many it takes to lose track, and how the open bar did the rest. She does not dance. She danced. There's a great-aunt who'll bring it up at holidays for years.

She got home, charged her phone, and opened Earshot. The app was there. Her shows were not. Her inbox was empty. The shelves were bare.

She didn't panic. She did the thing she always does first, which is assume she broke something and go looking for what. Closed it. Opened it again. Same empty shelves. Same quiet inbox. She thought about texting Renata and then didn't, because she wasn't ready to say out loud that she'd lost everything.

By the next morning it was back. All of it. Her shows in the right order, her inbox with the episodes she hadn't played yet, her position saved on the long one she'd been working through for a week. The app had just needed another launch to find where it had put things.

She texted Renata: "tell your nephew the app lost my stuff and then found it again." A pause. Then: "I'm choosing to be impressed."

The artwork loads instantly now. She noticed that the way you notice a sound stopping.

And there was one more thing. She's used this app long enough that some of its labels had turned into furniture. The play button was one of them. For a while VoiceOver read it as "Play or Pause Playing," a little knot of words she'd stopped parsing entirely. She just tapped it and listened for whether the audio started or stopped.

Now it says "Play" when it means play, and "Pause" when it means pause. That's all. It's a small thing. It is absolutely a small thing. But she was the one who'd mentioned that exact label to Renata months ago, half a complaint and half a shrug, so this one lands a little differently than the rest.

The inbox count moved too. It used to live only on the heading, so she'd have to open the inbox to find out how much was waiting. Now the tab itself carries the number. She can tell from the tab bar whether there's one thing or eleven without going in to look.

It's a little thing, again. But the app feels like it knows what it's doing when it tells her that before she asks.

**What to test:**

If you upgraded from an older build and your inbox or library looked empty, open the app and give it a moment. It should find your shows on this launch. Email michael@payown.media if anything is still missing.

Play an episode and listen to what VoiceOver says when you tap the play/pause button. It should say "Play" when paused and "Pause" when playing. Report anything that still reads "Play or Pause Playing."

Check the Inbox tab in the tab bar. It should show a count when you have unplayed inbox items, and no number when the inbox is empty. VoiceOver should announce it cleanly (you'll hear the number as part of the tab).

---

### Chapter 23 — Build 119

*At the wedding she had to wait in the dark and hope.*

The night everything vanished and came back (the wedding, the bare shelves, the next-morning relief) taught her one thing she didn't love: when it went sideways, all she could do was close the app and hope the next launch sorted it. It did. But hope isn't a setting.

This build puts one in. Down in Settings there's a Data section now, with a row that reads Import older data. It tells her where she stands: imported, and the date it last ran. If something from the old version didn't make it across, that's the button that goes back and gets it, on her say-so.

She found it the way she finds everything, looking for something else. Her shows were all there, her queue the way she left it, the long one she'd been a week into still sitting right where she'd stopped. After the wedding she'd half-braced for another empty-shelf morning. It didn't come.

What stayed with her was that the row was there at all. At the wedding she'd had nothing to do but wait. Now there's a door, and it's hers to open.

She'd put it the way she puts most things, if she put it to Renata at all: she doesn't need the app to be perfect. She needs to not be stuck in the dark when it isn't.

**What to test:**

Open Settings and find the new Data section. There should be a row called Import older data showing your status: not imported, imported on a date, or import failed.

Tap it and run the import. If your shows, your queue, or your place in an episode didn't fully come across from an older version, this should pull them back. Run it twice if you like. It won't double up your shows or your queue. VoiceOver should tell you how it went when it finishes.

We changed how your saved place is handled this build, so upgrading won't move it backward. If you ever do see your place jump back on its own, that's a bug now, email michael@payown.media.

---

### Chapter 24 — Build 122

*Kashe finally moves her own backlog into Earshot, braces for the worst part, and finds something already waiting for her on the other side.*

Kashe had a list she'd never moved. Years of shows in the app she used before this one, the kind of library you build when you never delete anything. She knows that's a problem. It's also her whole personality, so she's made her peace with it.

She'd put off bringing it over because she knew the shape of the bad part. Get the file out of the old app, get it into Earshot, then sit through the stretch where the screen does something and VoiceOver tries to keep up and mostly trips over itself. A hundred shows announcing themselves one after another while she waits to find out if any of it took.

This time she opened the file and there Earshot was in the share sheet, no detour. She picked it. And instead of the usual scramble, the app just told her where it was. Importing, this many of that many, one clean line she could check and move past. No flood. No stutter. When it finished, it said so plainly, and the shows were all there.

Then came the part she didn't expect. She opened her inbox bracing for nothing, that empty hallway you get right after a big import, all those shows and not one thing to actually play. Go dig, the old apps used to say. Instead the inbox already had something in it. The last few episodes of each show she'd just brought over, sitting there, ready. She'd moved her whole library and landed on something she could press play on right then, in the car, before her first client.

She poked at the rest while she had it open. Started typing the name of a show that wasn't on her old list, one she'd been meaning to find, and the results were filling in before she'd finished the word. That used to mean a pause, a held breath, a wonder whether it had heard her. Now it just kept up.

One small thing made her smile. The button doesn't say Subscribe anymore. It says Follow. She'd never minded Subscribe, exactly. But Follow is the truer word for what she actually does, which is keep an ear out, not sign a contract. Small thing. Right word.

She didn't text Renata about any of it. She just had something playing, which is the whole point.

**What to test:**

If you have an OPML file from another podcast app, open it and choose Earshot from the share sheet. You should see a clean progress screen with a running count, this many of that many, instead of the screen freezing or VoiceOver stuttering through every show. When it finishes, it should tell you how many came in.

After the import finishes, open your inbox. It should already have the most recent few episodes of the shows you brought in, something you can play right away, not an empty inbox you have to go digging through.

If you are new and setting up, look for the option to bring your shows in by OPML right during onboarding, before you've added anything by hand. The same inbox seeding applies, you should land on episodes ready to play, not a blank inbox.

Search for a show by name and watch the results fill in as you type. They should come up fast, without a long pause after each keystroke.

Anywhere you'd add a show, the button now says Follow instead of Subscribe. It does the same thing. If you spot a leftover Subscribe anywhere, email michael@payown.media.

### Chapter 25 — Build 123

*Kashe set her queue to group by show a long time ago. It never quite stayed set. This build makes it stick, gives the headings more to do, and lets her say how far playback should roll on its own.*

Every morning started the same way, and Kashe had stopped noticing the extra step.

Open Earshot, land on the queue, flip grouping back on. She'd set "Group by podcast" so long ago she couldn't tell you when. It was how she ran her mornings, news shows stacked together, the long interview saved for the drive. But every cold launch handed her back a flat list, one long run of episodes with no seams, and she'd turn grouping on again before she could plan anything.

She'd tried fixing it the obvious way once. There was a switch for it down in Settings, the same thing by another name. She turned it on and nothing happened. Off, on again. The queue did what it wanted regardless. So she filed it where she files things like that, under not worth the fight, and went back to flipping it on by hand each morning. One more part of the routine, like the coffee.

This build is the one where it stays.

She flipped grouping on, and VoiceOver said it plain: "Queue grouped by podcast." Then she did the thing she'd taught herself not to expect. Closed the app, opened it cold, landed on the queue. Still grouped. Her shows still in their own little stacks, right where she'd left them. She checked the switch in Settings out of old habit, half expecting it to argue with the queue the way it always had. It didn't. Both of them said the same thing now.

It's a small one. She knows it's a small one. But it's the kind of small she'd been paying for every single morning, a few seconds and a little friction she'd quit counting. Now the app remembers what she told it the first time, so she doesn't have to keep telling it.

Now that it held, she started living in it more than she used to. The headings stopped being just dividers and turned into where she runs the queue from.

There used to be a little button on each show's heading, just to play that whole show. It's gone now, folded into the actions rotor where the move options already live. She flicks down on a show's name and they're all right there: play the group, sort it newest first, sort it oldest first, shuffle it. Four ways to handle a whole show without touching a single episode.

Her news show, the one that posts three times a day, she sorts newest first so the latest sits on top where she wants it. The long interview show she's been saving, oldest first, so it plays in the order it came. And there's a backlog show she dips into with no plan at all, so she shuffles that one and lets it surprise her. None of them start playing when she sorts or shuffles. They just rearrange and say so, "Sorted newest first," "Shuffled," and she decides when to press play. Play group is the only one that starts the audio, pulling the show to the front and going.

One more thing turned up in Settings, and it fit the rest. There's an Auto-advance section now, two switches, both on the way the app had always quietly behaved. One keeps playback rolling after an episode ends. The other keeps it rolling after a whole show's queued episodes run out, on into the next show in line.

She'd never had a name for that second one. She just knew the nights it happened, drifting off to one show and waking to a different one entirely, a voice she didn't recognize talking about something she'd never queued. Now she could tell it to stop when a show ran out instead of wandering into the next. She left the first switch on and turned the second one off.

The one-off "Stop after this episode" is still right there in the player, separate from both switches, for the nights she only wants one more thing and then quiet. Nothing about it changed. It just has company now.

She flipped grouping off once more, just to hear what it would say. "Queue ungrouped." Fair enough. Back on, and out the door.

**What to test:**

Open your queue and turn on "Group by podcast." With VoiceOver on, you should hear "Queue grouped by podcast" when it turns on and "Queue ungrouped" when it turns off.

Go to Settings and find the "Group queue by podcast" toggle. It should already match what you just set on the queue. Flip it there, then go back to the queue. The queue should match. The two should always agree.

Leave grouping on, move around the app, and come back to the queue. Then force-quit Earshot and open it cold. Your queue should still be grouped. You shouldn't have to turn it on again.

Do the same with grouping turned off. It should stay off across navigation and relaunch.

In a grouped queue, put VoiceOver on a show's heading and open the actions rotor. You should find four actions: Play Group, Sort Newest First, Sort Oldest First, and Shuffle Group. There's no separate "Play group" button anymore. It lives in the rotor now.

Try Sort Newest First, then Sort Oldest First. The show's episodes should reorder within the group, and you should hear "Sorted newest first" or "Sorted oldest first." No audio should start. Try Shuffle Group. The group should shuffle to the front of the queue and announce "Shuffled," again with nothing playing.

Try Play Group. It should bring that show to the front of the queue and start playing.

Go to Settings and find the new Auto-advance section with two switches, both on by default (the behavior you already have). "Continue after episode ends" keeps playback going to the next item when one finishes. Turn it off and playback should stop after every episode. "Continue after group ends" keeps playback rolling from one show into the next when a show's queued episodes run out. Turn it off and playback should stop at the end of a show instead of rolling into the next one.

The one-off "Stop after this episode" in the player is separate from both switches and unchanged. It should still stop after the current episode no matter how the Auto-advance switches are set.

### Chapter 26 — Build 124

*Kashe opens the app to a current inbox instead of yesterday's, stops tripping over a loose number by the tab bar, and finally gets to put her giant library in an order she can use.*

For a while, opening Earshot first thing meant getting yesterday. The same episodes she'd already seen, nothing new on top, even though she knew three of her shows had posted overnight. She'd pull down to refresh and wait, or just shrug and figure the new ones would turn up by lunch. They usually did, eventually, on their own clock.

This build, she opened it and the new ones were already there. No pull, no waiting. The app had caught up the second she came back to it, which is all she'd ever wanted it to do.

Then there was the small thing she'd stopped noticing. Flicking across the bottom row, Inbox over to Queue, VoiceOver would land on the Inbox tab, say the count, and then catch for half a beat on the number again. Loose. By itself. Like a coin that fell out of the sentence. She'd taught herself to flick past it. This time it wasn't there. Inbox, then Queue, clean, the count said once where it belongs.

The big one was the Library. Hers is enormous, and she knows it, and we've been over that. It had always come back in the order she added things, newest follow up top, which meant a show she'd had for years lived somewhere in the middle of a list she couldn't really scan. Now there's a Sort button up top. She set it to alphabetical and the whole shelf fell into an order she could move through by letter.

One show made her laugh. The Archers, an old one, filed under A. Not T. The app had the sense to skip the The. That's the right call. She'd have done it the same way.

There's a second way to sort too, by last published, the shows with the newest episodes riding on top. She tried it and her three-times-a-day news show jumped to the front while the ones that had gone quiet sank to the bottom. Two ways to look at the same shelf, and she got to pick. She thought about the woman on her Tuesday route, the one she'd helped move a library over, who'd asked her once how she ever found anything in a list that long. Now there's an answer that isn't just keep scrolling.

She set it back to alphabetical and left it. Opened her inbox one more time, current as of a minute ago, and pressed play before the first client.

**What to test:**

Leave Earshot closed for a while, ideally fifteen minutes or more, and best of all when one of your shows tends to post. Open it back up. New episodes should already be in your inbox without you pulling down to refresh. Open it again right away and it should not refetch every single time.

With VoiceOver, put focus on the Inbox tab and listen for the count. Then flick right toward Queue. You should go straight to the Queue tab with no extra stray number in between. The count is still spoken once, on the Inbox tab itself.

Open your Library and find the new Sort button at the top. Alphabetical should order your shows A to Z, and it should file "The Archers" under A, skipping a leading The, A, or An. Last published should put the shows with the newest episodes on top.

Switch the sort, force-quit Earshot, and open it cold. It should stay where you set it. With VoiceOver the Sort button tells you the current order, and choosing one announces "Sorted by" and the order you picked.

### Chapter 27 — Build 125

*Kashe keeps living in the grouped queue from Chapter 25, and this build finally lets her hand-order it without leaving VoiceOver. Her earbuds learn to skip the way she means, too.*

The grouped queue stuck (Chapter 25), so she'd been running more of her day out of it. Stacks of shows, headings she could act on. What she couldn't do, until now, was nudge things by hand.

Say her news show had four queued and she wanted today's interview ahead of yesterday's recap. She'd flick the rotor on the episode and find, well, not much. Play it, open the notes, remove it. That was the list. No move up, no move down. And remove sat there twice, the same action said back to back, like the app had a stutter. She'd learned to ignore the second one.

This build gives the episode somewhere to go. Flick down on a queued episode inside a grouped show and there's Move up and Move down, and they keep her inside that show. Move one down and it trades places with the next episode from the same show, stepping over the other shows in between like they aren't there. Her interview show stays her interview show. Nothing leaks across.

And the doubled remove is gone. One Play, one Remove from queue, one Open show notes, plus the two moves. Each thing said once.

The headings got the same idea, one level up. On a show's name she already had play, sort, and shuffle (Chapter 25). Now there's Move Group Up and Move Group Down, so she can take a whole show, every queued episode of it at once, and lift it above the next show or drop it below. The block moves together, and VoiceOver lands her right back on the heading she moved, so she can move it again without going to look for it. She pulled her morning news show to the top of the queue in two flicks and left the long stuff underneath.

Then the part that has nothing to do with the queue and everything to do with how she actually listens. Her earbuds. Hands full, phone in a pocket, she'd reach up to skip past an ad and instead the whole episode would vanish and a different one would start. The skip press was getting read as next track. So she'd quit using it and just sat through the ads.

Now the skip on her earbuds skips. Forward jumps ahead inside the episode, back jumps back, same as the buttons on screen. It stays in the thing she's listening to. For someone who runs the app by feel, from a pocket, between two clients, that's the one she'll feel every single day.

One last quiet thing. That subscription list she'd helped Renata carry over on a Tuesday, the OPML file, opens straight from Files now instead of stalling out. If someone hands her their shows, she can take them in a tap.

She moved her news show to the top, skipped past an ad without looking, and went in.

**What to test:**

Turn on Group by podcast in your queue. With VoiceOver, put focus on a queued episode that has other episodes from the same show, and open the actions rotor. You should find Move up and Move down, and you should hear Remove from queue only once, not twice.

Try Move down. The episode should swap with the next episode from the same show, skipping over episodes from other shows. Move up should do the reverse. On the first or last episode of a show, the move should do nothing and stay silent (no false "Moved" announcement).

Put VoiceOver on a show's heading and open the rotor. Along with Play Group, Sort Newest First, Sort Oldest First, and Shuffle Group, you should now find Move Group Up and Move Group Down. Try one. The whole show should move as a block above or below the next show, and focus should land back on that same heading. At the very top or bottom of the queue, it should do nothing.

With wired or wireless earbuds (or the lock screen controls), start an episode and use skip forward and skip back. They should jump forward and back inside the same episode, not switch to a different episode.

If you have an OPML subscription file in Files, open it and choose Earshot. It should import your shows instead of stalling.

### Chapter 28 — Build 126

*The app gets quieter and quicker under VoiceOver while something's playing. Kashe runs her whole day with audio on, so this is the one she feels everywhere at once.*

Here's the thing about how Kashe actually uses Earshot. There's always something playing. She's not stopping the show to check the inbox or shuffle the queue. The audio runs while she flicks around with VoiceOver, one-handed, between two clients.

And for a while that's exactly where the app dragged. Show going, and every flick came a half-beat late. The inbox especially. She'd open it mid-episode and VoiceOver would stutter, like it was waiting in line behind the playback. She figured that was the cost of doing two things at once, and learned to let it catch up.

This build keeps up. The inbox stopped quietly redoing the same work over and over while a show played, so flicking through it during playback is quick now, not syrupy. The episode, queue, and bookmark lists got the same once-over, a little less busywork on every move, so each flick lands when she expects it.

Then the scrubber, the seek bar in the player. It used to re-announce its own name every second while the time ticked, talking over itself. Now it says its name once and just updates the time in the value. She can sit on it and hear where she is without it interrupting itself.

Last one, while scrolling. Her Library is huge, we've been over that. Cover art used to get unpacked at full size right as she scrolled past, on the same thread doing the talking, so a fast flick down the list would hitch. Now the art comes in already sized for the row, off to the side, and the scroll stays smooth under her finger.

None of it is a new button. It's the app getting out of its own way while it works. For someone who never turns the audio off, that's most of the day.

**What to test:**

With VoiceOver on, start an episode playing. While it plays, flick through your Inbox. It should stay quick, not lag behind the audio. Same for the Queue, your episode lists, and bookmarks.

Open the full player and put focus on the seek bar. It should say "Playback position" once, then update the time in its value (like "12 minutes of 42 minutes"). It should not re-read its name every second. Swipe up or down still jumps 30 seconds.

Open your Library and scroll fast with VoiceOver while audio plays. The list should feel smooth as artwork comes in, no stalls. Lock screen and Control Center artwork should still look right.

### Chapter 29 — Build 127

*Kashe finally gets queue actions that say what they do, and the one she means by "next" actually plays next.*

She never loved the two names. To put an episode at the front of her queue, the rotor said "Add to queue, top." For the back, "Add to queue, bottom." Top and bottom. She knew which was which, but only because she'd drilled it in. Every time, a half-second of translating. Top means soon, bottom means later. Like reading a map to cross your own kitchen.

Now they say it plain. "Play next" and "Add to end of queue." The one she wants up front is the one that plays after whatever's on. The long show she saves for the drive home goes to the end, where she's been parking it for months. No translating.

And Play next got honest about the word next.

Here's where it used to bite her. She keeps her shows grouped, and she'd turned off Continue after group ends so one show doesn't bleed into the next while she's driving. Good. Except when a client mentioned something and she flicked over, found the episode, and hit Play next, it would land behind the playing show and then just stop. Her current show ended and the app went quiet, because the next one was a different show and she'd told it to stop at the edges. The thing she asked for got swallowed by a rule she set for something else.

Now Play next wins. If she says play this next, it plays next, group rule or not. The stop-at-the-edge setting still does its job everywhere else. It just stops arguing with her when she's pointing right at the thing.

She told a client's daughter about a show, Play-nexted her own note-to-self, and it came on right as the last one ended. No silence to fill.

**What to test:**

With VoiceOver, open the actions rotor on any episode. The two queue actions now read "Play next" and "Add to end of queue" instead of top and bottom. Play next puts the episode right after what's playing. Add to end of queue puts it last.

If you group your queue and have turned off Continue after group ends in Settings, Auto-advance: start a show, then Play next an episode from a different show. When the current one finishes, your Play-nexted episode should play, even across the group line. Normal auto-advance at a group edge should still stop the way you set it.

### Chapter 30 — Build 128

*Kashe stops opening menus to change a number. She flicks.*

Kashe stopped opening the speed menu. She just flicks now.

Speed is a thing she fidgets with. A dense interview show she takes at 1.5. A guy who already talks fast, she pulls back to 1.1 so she catches the asides. Changing it used to mean: find the speed, double tap, wait for the sheet, find the number in a grid, tap it, close the sheet. Five steps to nudge one notch.

Now she lands on the speed in the player and flicks. Up a touch, down a touch, and it says the new speed back to her as she goes. One and a half. One and a quarter. One. No sheet, no grid, no hunting.

The whole app works that way now. Anything that's a number you pick, you flick to change. Her sleep timer, the one she leans on at night when she drifts off mid-episode, is the same. Flick up for more time, down for less, all the way down to off. She doesn't feel around for a row of buttons in the dark anymore. She finds the timer and rolls it to where she wants.

It's the difference between operating a thing and just adjusting it. Like the volume knob in an old car. You don't look at a knob. Your hand knows.

She set a fast talker back to 1.1 on the drive out to her Tuesday client, heard "one point one times," and didn't think about it again.

What to test:

With VoiceOver, open the player and find Playback speed. Flick up to speed up, flick down to slow down. It should change right away and speak the new speed each time. To reach the full options (per-podcast, precise steps, reset), use the Actions rotor and choose "Open speed options."

Open the Player controls (the sliders button, top right) and find the Sleep timer. Flick up for a longer timer, flick down for shorter, and down again to Off. The same flick-to-change now works on the speed, skip, and limit settings throughout Settings and per-podcast settings too.

### Chapter 31 — Build 131

*Kashe finds a show she wants from the very beginning, and for once the app lets her hear it in order.*

**What to test:**

Open a podcast in your Library. At the top of its episode list there's a new All / Unheard filter. Unheard hides episodes you've finished; All shows everything. It defaults to Unheard and remembers your choice per show. With VoiceOver it announces the selection and the new count when you switch.

Select a podcast and tap Play oldest first. It should play that show's episodes from oldest to newest and keep going through the show, instead of jumping to a random inbox episode when one ends. It follows the All/Unheard filter you've set, and it leaves your existing queue alone.

She'd found a show worth starting from the beginning. Not the latest one. The first, then the next, in order, the way the people who made it meant it to go.

That used to be a fight. She'd open the show, find the oldest episode, play it, and the second it ended Earshot grabbed something else off the top of her inbox. A different show, a different voice. She'd back out, find her place, start the next one by hand. Three taps to move one episode forward. She gave up and listened newest first, which is a strange way to hear anything with a thread running through it.

This build put a Play oldest first right on the show. She tapped it once. It started at the beginning and stayed there, episode after episode, rolling forward instead of wandering off. Her queue, whatever she'd lined up for the drive, sat untouched underneath.

And the list kept itself clean while she worked through it. The filter up top, All or Unheard. On Unheard the ones she'd finished fell away, so the next morning the show was just what was left, not a wall she had to find her spot in. When she wanted one she'd already played, she flicked to All and there it was.

She set it going oldest first, left it on Unheard, and let the show tell itself to her in the right order for once.

### Chapter 32 — Build 132

*Kashe lands on a screen and hears where she is before what she can do to it, and the Queue tab finally tells her how much is waiting.*

**What to test:**

With VoiceOver, open each of the five tabs: Inbox, Queue, Library, Downloads, Settings. On each one the screen's title should read first, as a heading, before any toolbar or options buttons. Before this, you'd hear something like "Queue options" before the word Queue.

Check the Now Playing bar that sits above the tabs while something's loaded. It should read as one group labeled "Now Playing," not as loose, scattered controls.

Look at the Queue tab in the tab bar. With episodes queued it should show a count and a red badge, and VoiceOver should say "Queue, N items," the same way the Inbox tab already does. No stray extra number when you flick past it.

She runs the whole day off the bottom tabs, we've been over that, and lately mostly off the Queue (Chapter 21, Chapter 25). So she knows the exact shape of landing on a screen. Flick into a tab and the first thing the app would hand her, before the name of where she was, was the button to do something to it. "Queue options." She'd be acting on a place before she'd been told she'd arrived.

She'd stopped hearing it, the way she stops hearing most of these. You learn to wait one beat for the title and skip whatever comes ahead of it.

This build leads with the title. Inbox, Queue, Library, Downloads, Settings, each one says where she is first, as a heading, then the buttons. She lands and she knows she's landed. The Now Playing bar pulled itself together too, one tidy group with its name on it instead of a handful of stray controls she had to sort by feel.

And the Queue tab finally carries its number. The Inbox tab has told her how much was waiting for a while now (Chapter 22). The Queue never did, so she'd open it just to find out how deep the morning was. Now the count rides on the tab, said once, clean. She can tell from the bar whether it's two things or twelve before she goes in.

Small ones, both. But she touches that bar more than anything else she owns.

### Chapter 33 — Build 133

*Kashe's app finally opens where she told it to, the queue stops hoarding stale newscasts, and every row tells her how much time is left.*

**What to test:**

Set Settings, General, Default launch screen to Queue (or anything but Inbox). Force-quit Earshot and open it cold. It should open to the screen you picked, not always Inbox.

In Queue, Inbox, and Library, each episode row now shows time: "X min left" on one you've started, or the full length on one you haven't. Check the number matches where you are.

With VoiceOver, flick through episode rows. After the title, show, and time, you should hear a short one-sentence summary of the episode.

If you cap a show in its Inbox settings (say a news show kept to 1), its auto-queued episodes shouldn't pile up forever in the Queue. The oldest auto-queued ones drop off so only the newest stay. It won't remove the episode that's playing, or anything you sent with Play next.

She'd set it to open on the Queue ages ago (Chapter 9), back when one extra tap a day was worth fixing. Somewhere along the way it forgot. Cold launch kept dropping her on the Inbox, and she'd flick over to the Queue without thinking, the way you re-tuck a shirt. This build it lands where she told it. Queue, first thing, no detour.

Then the thing she hadn't caught. Her news show posts three times a day and she keeps just the latest in her inbox (Chapter 19). But the queue had been hoarding. Every newscast it auto-added stayed, a little stack of yesterday's and the day before's, stale by the time she reached them. Now the queue holds the same line: newest few, the old ones fall off on their own. It won't touch the one that's playing, and it leaves alone anything she sent with Play next (Chapter 29).

And the rows started telling her time. Not just a title now, but how long, and on the ones she's partway into, how much is left. "Twelve minutes left." She reads the queue before a stop and knows what fits in the driveway and what waits for the road. VoiceOver says it too, with a quick line on what each one's about, before she's opened a thing.

### Chapter 34 — Build 134

*Renata mentions a show again, and for once Kashe gets to look before she leaps, then drops one she never meant to follow without leaving her inbox.*

**What to test:**

In Search, find a podcast and Activate it (double-tap). It should open a preview with the show's description and recent episodes, not follow it on the spot. "Follow" is now a real toggle: follow it and the button reads "Unfollow." With VoiceOver, focus a result, use the rotor "Follow" action ("Now following X"), then it reads "Unfollow."

Swipe an Inbox row and choose "Unfollow this podcast." Confirm when asked. It removes the whole show and its episodes. VoiceOver users reach it as a rotor action.

In Search results, each result announces "result N of M," and a count is spoken when results settle. Touch the far-right edge of the list for the native iOS vertical scroll bar ("vertical scroll bar, adjustable") and flick up or down to jump about ten percent. If you use VoiceOver, please confirm that right-edge gesture on your device.

Queue rows now show "X min left" or full length, spoken and visible, matching the other lists.

Renata mentioned a show again. Easy, the way she does, like it costs nothing, knowing exactly where it lands on Kashe's pile.

This time Kashe searched it instead of following on faith. She found it in the results and double-tapped, braced for the old thing where a tap meant she'd already followed, one more name on the heap. Instead it opened. The description, the last few episodes, room to decide. She read a bit, heard what it was, and then chose. Follow. The button turned to Unfollow, plain, like it had been waiting for her to mean it.

The results read themselves out now too. Result four of nine, so she knew how far down she was instead of swiping into the dark.

And the other end of it, the pruning she's put off for years, got easier. A show she'd followed on a whim turned up in her inbox and she swiped the row. Unfollow this podcast. Gone, show and episodes both, no trip to a settings screen to find the door.

She didn't clean up the whole list. She never does. But she followed one on purpose and dropped one without a fight, same morning. For her that's new.

### Chapter 35 — Build 135

*The long show she saves has a stretch she's always skipped by feel; this build gives it chapters she can aim at, name, and tell the app to step over.*

**What to test:**

Play a chaptered show. The current chapter now shows under the title and updates as it plays. Use Previous chapter / Next chapter to jump between them; with VoiceOver they're rotor actions on the artwork, and each jump announces the chapter name.

Activate the chapter name to open the chapter list. Tap any chapter to play from there. With VoiceOver each chapter is one stop; double-tap to jump. Use the rotor action "Skip this chapter" to deselect one so playback skips it, "Include this chapter" to put it back. All chapters play by default; skip choices last the listening session.

In Search, results now count correctly: "result 1 of N, 2 of N, 3 of N." Duplicate listings of the same show are gone and the count is honest.

The long interview show she keeps oldest-first has a stretch in the middle of every episode she's never wanted. Housekeeping. Sponsor reads, a listener-mail bit, ten minutes before they get to the guest. For years she'd thumbed the skip button in the dark, guessing, overshooting, backing up, landing wrong twice before she gave up and sat through it.

This build gave the show its chapters. The player tells her which one's playing now, right under the title. She can step Previous and Next, and it says the name as she goes. The intro. The mail bit. The guest. She found the name, opened the list, and there the whole episode was, laid out in pieces she could aim at.

Better than that, she told it to skip the parts she skips. Flicked to the sponsor chapter, "Skip this chapter," and the next time around the show stepped over it on its own. Quiet where the ten minutes used to be. It forgets by morning, which is fine. She'll tell it again.

She jumped straight to the guest and let the rest keep itself.

### Chapter 36 — Build 136

*Last build gave her chapter controls but her own MP3 shows came up empty; this build reads the chapters embedded in those files so they finally appear.*

**What to test:**

Play a chaptered MP3 show, the kind made with tools like Auphonic (a long-running tech show is a good bet). The chapter list should now populate where it used to say "No chapters." It works while streaming, just hit Play, no need to download first.

Confirm the current chapter shows under the title and updates as it plays. Previous chapter / Next chapter jump and announce the name. Activate the chapter name to open the list, then tap a chapter to play from there. With VoiceOver, the rotor "Skip this chapter" steps over it on playback.

If you download the episode, the chapters should still show, read from the local file.

Last build handed Kashe chapters and she went straight to the show she'd wanted them on most. Her tech show, the one she's followed for years, the kind that runs long and wanders before it gets where it's going.

She opened the list and it said No chapters. Empty. The thing she'd just been given, missing on the one place she'd have reached for it.

She didn't say anything. Figured maybe that show just didn't do chapters, or the app only managed them on some and not others. Filed it under the usual: a thing that works in the demo and not in your hands. She'd had a build tease her before.

This build it's there. Same show, same Play, and the list came up full. The segments laid out and named, the way the people who make it must see them when they put it together. Streaming, no download first. She hit play and they were waiting.

The pieces had been inside the file the whole time. The app just hadn't been reading them. Now it does, even while it's pulling the show down over the air, and still does once it's saved to her phone.

She flicked to the part she always skips, told it to step over, and let the rest run.

### Chapter 37 — Build 137

*Kashe has been moving through chapters by the VoiceOver rotor; this build puts plain Previous and Next buttons right beside the chapter name, and lets her hide them if she'd rather not.*

**What to test:**

Play a show with chapters (one of the chaptered shows from the last couple of builds works). In the player, a chaptered show now shows a Previous chapter button to the LEFT of the chapter name and a Next chapter button to the RIGHT. Tap them to jump back or forward a chapter.

These buttons are on by default.

If you'd rather move through chapters with the VoiceOver rotor on the artwork, or just want a cleaner player, go to Settings, Playback, "Chapter navigation buttons" and turn it off to hide them.

Hiding the buttons never takes chapter navigation away. The artwork rotor Previous chapter / Next chapter actions still work whether the buttons show or not.

She'd been moving through her interview show by the rotor, flicking on the artwork to find Previous or Next chapter, then flicking again to fire it. It worked. It was a couple of steps, every time.

This build set two buttons right next to the chapter name. Previous on the left, Next on the right, a fixed spot she could land on and press, no digging through the rotor for the action first. She tried them a few mornings. Liked knowing exactly where they sat.

Then she went into Settings, Playback, and found the switch that hides them. Thought about it. Left it on. The rotor's still there under the artwork if she wants it, and now there's a button too. For once the app handed her both and let her keep whichever one her thumb went for.

### Chapter 38 — Build 139

*Kashe could read a show in the search preview but never hear it; this build lets her play an episode straight from there, streaming, and cleans up the descriptions that used to come through as raw HTML.*

**What to test:**

In Search, find a show and open its preview (double-tap a result). Tap any episode in there and it should start playing right away, streaming, with no need to Follow first. Nothing gets added to your library or queue, it just plays.

Open a show whose description used to come through as raw HTML, literal tags and code-looking text instead of words. The description should now read as clean, normal text. With VoiceOver, it should speak the readable text, never the tag soup.

She'd learned to look before she followed (Chapter 34). A name turns up, Renata mentions something, and she searches it, opens the preview, reads what it is before she commits to one more show on the pile.

But the preview only got her so far. She could read about a show. She couldn't hear it. To actually listen she had to follow first, then go dig it out of her library, then back it out if it wasn't for her. So mostly she'd guess from the description and follow on faith, which is how the pile got to be a pile.

This build she taps an episode right there in the preview and it plays. Streaming, nothing saved, nothing queued. Just the show in her ears so she can tell in two minutes what a paragraph never could. She played ten minutes of one, decided it wasn't for her, closed it. Nothing to undo.

And the description itself reads like a person wrote it now. One show she'd checked used to hand her a mess, literal tags and bracket-clutter where the words should be, and she'd read around it the way she reads around most things. This time it was plain sentences, start to finish. She didn't have to translate.

Look, then listen, then decide. For someone who's followed too much and pruned too little, that's the order she's wanted the whole time.

---

### Chapter 39 — Build 140

*Kashe streams on spotty roads and had given up on reordering her Quick Actions; this build makes streaming pick itself back up after a buffering dip, and lets her reorder those actions by VoiceOver instead of a drag.*

**What to test:**

On a weak connection, stream an episode (don't download it) and let a buffering dip happen without touching the phone. Playback should pick itself back up on its own, no manual play tap. If you pause it yourself, it should stay paused.

Go to Settings, Quick Actions. Focus a row, open the Actions rotor, and use Move to top, Move up, Move down, or Move to bottom to reorder them, for example putting "Play now" first. No dragging needed.

Not every drive is out past signal. Most are just spotty. A stretch of road where the bars drop to one and the show she's streaming hits a wall, goes quiet, and used to stay quiet until she found the phone and pressed play again.

Both hands are usually busy when it happens. A wheelchair half into the trunk. By the time she got to the phone the quiet had been sitting there a while, and she'd missed whatever she missed.

This build the quiet doesn't last. The show dips, waits out the bad patch, and comes back on its own. She caught it the second time and then stopped catching it, which is the point. The phone ran cooler through the rough stretch too, not the warm brick it used to be by the far end of the route.

Then the Quick Actions. She'd set them once and never touched them again, because touching them meant dragging a row to a new spot, and a drag you can't see is a drag you can't do. So "Play now" sat wherever it had landed, third or fourth down, and she reached past the rest to get to it.

This time the reorder lived in the rotor. Move to top. She put Play now first, so one flick does the thing she does most. No dragging, no guessing where the row went. She wondered why it took this long, then let that go too.

---

### Chapter 40 — Build 142

*(Canon note: these notes shipped on builds 142 and 143. Build 142 (1.0.0) stalled in Public beta review, so build 143 (0.1.0) re-shipped the same content.)*

*Kashe's show notes links finally work, her rows tell her what's downloaded versus streaming, transcripts open from the player, and the privacy screen gets shorter and truer as the version quietly turns 1.0.0.*

**What to test:**

Open an episode's show notes. Links should be tappable and open in your browser, and bold and italic should read as text, not tags. With VoiceOver, links announce as links. No images or trackers load.

On episode rows and in Now Playing, each episode says whether it's Downloaded, Downloading, or Streams when played. VoiceOver should speak that state.

When an episode has a transcript, open it from Now Playing. The text should read cleanly whether it came as VTT, SRT, JSON, HTML, or plain text.

In a show's episode list, open the sort menu and pick Alphabetical, Latest first, or Latest last. The order should change and VoiceOver should announce your choice.

Start a download, then close the app fully. Come back later. It should have kept going and finished on its own.

Privacy: onboarding and Settings now say plainly that Earshot collects no data, the old crash and analytics toggles are gone, and Settings shows version 1.0.0. Settings, Appearance also has theme, accent, and density, and Inbox and Downloads rows now say the show's name after the title.

A name comes up on the drive between clients, a resource somebody swears by, and it's sitting right there in the show notes as a link. It used to be dead text she'd read out and try to remember and never did. This build she taps it and it opens. No image clutter loading behind it, nothing following her out the door.

She's learned which stretches of her route go dark. So before one she checks the rows, and now the rows tell her: Downloaded, Downloading, Streams when played. No more guessing which show is actually on the phone. She queued three, saw two already down and one still coming, closed the app, drove. It finished while the app was shut. When she hit the dead patch the shows were just there.

One show she'd want to read back, not just hear. The transcript opens from the player now, plain text, hers to scroll.

On the way out she passed the version. 1.0.0. Earshot collects nothing, the screen says now, and for once the words match what the app was already doing. Renata had called it rough around the edges, back before any of this. Kashe didn't text anyone. She just noticed.

---

### Chapter 41 — Build 144

*The rotor Kashe reordered last build had been reading her list backwards; this build reads it her way, drops a doubled Mark as played, and makes Unfollow a Quick Action she can place herself.*

**What to test:**

Set your order in Settings, Quick Actions. Then flick down on any episode row with VoiceOver: the Actions rotor should offer your actions in that exact order, first one first. It used to read the list exactly backwards. If you'd reversed your settings to compensate, straighten them out; the order holds now.

Flick through a row's actions: "Mark as played" should be listed once, not twice.

Settings, Quick Actions has a ninth action: "Unfollow this podcast." Reorder it like the rest. Fire it from a row in Inbox, Downloads, or a show's episode list; it asks to confirm, then removes the show and its episodes. It doesn't appear on search preview episodes, and the sighted swipe still works with VoiceOver off.

Last build she moved Play now to the top (Chapter 39). What she never said was what happened next. She flicked down on an episode and Play now came up last. Dead last, after everything she reaches for least. She checked Settings. First, right where she'd put it. Back on the row: last. The list was coming out backwards.

She didn't report it. She reversed the whole list instead, upside down in Settings on purpose so the rotor would read it right side up. Two minutes. One flick fired Play now, same as promised. She just never said what it cost.

This build reads the list the way she wrote it, which meant her upside-down workaround came out backwards on the first flick. She went back to Settings and put the list in plain order for the first time. First is first. It held.

The stutter went with it. Mark as played had been showing up twice in the actions, the same words back to back, and she'd learned to flick past the echo like the doubled Remove from a while ago. Said once now.

And there's a ninth action to place: Unfollow this podcast. The pruning swipe is hers to position now. She put it at the bottom. A thing that removes a whole show should be a reach, not a reflex. It asks first. She's already used it twice.

---

*More chapters added here as Earshot ships.*
