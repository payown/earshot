# Build 268 changes since TestFlight build 267

Last distributed build: 1.2.3 (267), App Store Connect build
`9cae8cad-a327-416b-ad2f-dbecc9162eff`. Its archive source was `41ad72c9`,
release packaging PR #980, incorporated into main as `564c2658`.

All app changes after that release are included:

| PR | Changes and testing focus |
| --- | --- |
| #981 | Defer unopened Queue/Downloads screens at launch; reuse Downloads episode and expired-row data; calculate current chapter once per list evaluation. Add optional Hide caught-up podcasts in Library. Check first tab entry, preserved navigation, downloads updates, chapter changes, and filter on/off. |
| #982 | Optional device-local downloaded-unheard Home Screen badge, off by default. Preserve notification opt-in after badge permission. Check completed/removed/heard downloads, requeued heard episodes, permission denial, and disable/clear. |
| #983 | Persist Library episode sort separately for each podcast. Check oldest-first drama and newest-first news across reopening. |
| #984 | Request up to 200 directory results; remove repeated library relationship work during search result rendering and dictation updates; preserve relevance, Follow state, VoiceOver positions and focus. Provider may return fewer results. |
| #985 | Reuse folder selections and hierarchy during folder-picker rendering. Check both picker directions, nested membership, and selected states. |
| #986 | Avoid per-row full Queue traversal in ungrouped rendering. Check filtered numbering, reorder, removal, and responsiveness. |
| #987 | Expand to 24 App Intents and ten supplied shortcuts; share background player preparation; add chapter, Queue, library/directory/category, audio-setting, timer, seek and bookmark actions; expand App Entities and add an in-app Shortcuts guide. |

The complete Chapter 90 is identical in `docs/kashe.md` and
`docs/testflight/build-268-notes.txt`. Testing priorities precede the story.
BBC insecure media redirects remain unresolved. Generated chapters, Snipcast
integration, and a configurable compressor/equalizer are not part of this build.

Release scope: TestFlight Internal Testing Group and Public Testers, explicitly
authorized by Michael September 25. No App Store release submission.
