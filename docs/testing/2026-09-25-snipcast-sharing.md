# Episode sharing and Snipcast investigation

StartTesting feature: `99d6acc9-3249-410d-b07e-33e09c225954`.
Base: main `f0c3306b`, TestFlight 1.2.3 (270).

## Evidence and scope

The listener reports that sharing an Earshot episode to Snipcast does not work,
while sharing from Castro does. They describe a Snipcast-to-Listen Later spoken
summary workflow. No exact error, episode, custom shortcut or account setup was
provided. Those downstream steps have not been reproduced.

The [official Snipcast guide](https://snipcast.io/articles/ios-shortcut/) links
[Summarize with Snipcast](https://www.icloud.com/shortcuts/6f4797f2e11944b685e1085953f5f20f).
Its publicly shared workflow was retrieved read-only on September 25 through
iCloud's public record/download API. The workflow accepts URL/app content and
places ExtensionInput directly in the text-valued `podcastUrl` request field;
it contains no explicit action to extract one URL from mixed input. It requires
the user's API key in Shortcuts. No shortcut was installed or executed, no key
was accessed, and no summary request was submitted during this investigation.

Earshot's five episode-sharing surfaces supplied `[episode.title, audioURL]` as
two independent activity items. This can introduce extra text into workflows
that use shared input directly. The exact Shortcuts coercion on the listener's
device remains unverified. A URL-looking episode title is especially ambiguous
when a receiver extracts URLs from multiple inputs.

The [Snipcast supported-player list](https://snipcast.io/) names Spotify, Apple
Podcasts, Pocket Casts, Overcast and Castro. It does not establish that a raw RSS
enclosure URL works. This change corrects the outgoing payload shape; it does
**not** claim proven Snipcast backend support for all audio URLs. If a clean URL
is rejected, record the exact public URL and error before choosing a supported
platform-link resolver or requesting provider support. Do not invent an Apple
Podcasts/Castro episode link or match a different episode by title alone.

## Change

Inbox, Downloads, folder episode lists, Library episode lists and Search share
one URL activity item. The title is supplied through link-preview metadata and
the subject, not as a second text item. Placeholder, actual payload and declared
content type all identify a URL. Every receiving activity gets the same remote
audio URL; no new network lookup, app account, schema or capability is needed.

HTTP URLs and signed query strings are preserved. Empty, relative, file and
non-web values retain a title-only fallback instead of offering a misleading
URL. Podcast sharing, bookmark text, transcript export and audio-file export
are unchanged. Existing Share actions and their labels/focus routing remain.

## Validation

Xcode 27.0 / iOS 26.5 simulator: 103 focused tests passed, zero failures. Tests cover the one-item URL contract,
placeholder/type agreement, title metadata, copy/mail/message/custom receivers,
URL-looking titles, signed queries, HTTP, and invalid/non-web input. Existing
quick-action and bookmark-sharing tests are included.

## Phone acceptance

1. Use a public episode that previously failed. Choose its Share action, then
   Copy. Paste into a temporary note: it should contain just one audio URL, not
   the episode title followed by a URL. Delete the temporary note afterward.
2. Share that episode to the user's configured Summarize with Snipcast shortcut.
   Confirm it identifies the correct episode and starts summarization. If it
   fails, record the error and public episode rather than assuming the payload
   change guarantees provider compatibility. Keep private feed credentials out
   of feedback. Configure the API key only in the user's own Shortcuts app.
3. Repeat Share from Inbox, Library, Downloads, Search and a folder. Check the
   title preview and VoiceOver Share action/focus. A mail draft should retain
   the episode title as its subject; cancel the draft without sending it.
4. With the user's existing Snipcast/Listen Later setup, confirm the spoken
   summary arrives and can be played in Earshot from the subscribed summary
   feed. Earshot does not create or configure that external workflow.

Keep the feature in testing until a real Snipcast submission and the documented
spoken-summary return path are verified. No merge, phone install or TestFlight
release is implied by the payload tests.
