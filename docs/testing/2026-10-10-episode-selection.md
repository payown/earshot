# Episode selection commands — implementation plan

## Listener request

Select all episodes or invert a selection, then mark all but a few episodes of a podcast played.

## Scope and behavior

1. Add Select all and Invert selection while selecting episodes in a podcast or Inbox. Podcast commands apply to the full current filter and search result, including unloaded pages; Inbox commands apply to the currently filtered Inbox. Fetch podcast identities in read-context batches and cancel stale requests when the scope or selection session changes. Selection stays in selection mode and the existing count announcement reports the result.
2. Add Mark selected as played and Mark selected as unplayed to the podcast selection bar, with a count-scoped confirmation that explains download and Inbox effects. Only episodes needing the requested change mutate. Preserve other played timestamps, sticky Inbox dismissal, download cleanup settings, and existing post-save notifications. Exit selection when the action finishes. Folder and Queue actions stay limited to 1,000 selected rows so whole-podcast selection does not materialize an enormous array for those actions.
3. Keep existing row labels, traits, and focus behavior. State the selection scope in the menu so a listener knows what Select all covers. Leave the whole-podcast Mark all as played action unchanged.
4. Test select-all, invert, filtered/search scope, unloaded pages, and selected-only played changes. Run focused iOS tests, independent review, then CI and TestFlight release checks.

## Acceptance on a phone

In a podcast with more than 100 episodes, select all matching episodes, deselect a few, and mark selected as played. Confirm the exceptions stay unplayed, including with Unheard and search filters. Switch to All, select played episodes, and mark selected as unplayed. Check they remain out of Inbox if previously dismissed. Check VoiceOver count, row state, focus, and responsiveness. Repeat selection commands in a filtered Inbox.

## Local verification

The focused selection, data-source, repository, and confirmation-copy tests passed on the iOS 26.5 simulator. A 5,000-episode diagnostic fetched matching identifiers in 0.0063 seconds while the rendered page remained at 100 episodes. The optional 45,436-episode fixture took more than three minutes to construct before the query and was stopped; that scale has not been measured. Physical VoiceOver behavior remains a TestFlight acceptance item.
