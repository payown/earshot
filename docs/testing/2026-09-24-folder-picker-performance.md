# Folder-picker performance and related audit

StartTesting feature: `8002bb54-81e3-4e45-87aa-ad7876d01f84`.

Michael requested additional performance improvements while he verified the
separate search/dictation build. This branch starts from main cee9bd97 and does
not replace that ongoing phone test.

## Implemented

FolderPodcastPickerView previously scanned all memberships for every podcast
row. PodcastFolderPickerView did the same for every folder row. Both now derive
a set of selected PersistentIdentifiers once per current query update, then use
set membership for rendering. PodcastFolderPickerView also builds its ordered
hierarchy once, rather than once for the empty check and again for the rows.

There is no persistent cache. Queries and existing model observation trigger
recomputation; the existing membershipVersion invalidation remains in the inverse
picker. Action handlers still consult live membership before add/remove writes.
Duplicate rows collapse to one selected ID; missing relationships are ignored;
child-folder membership does not imply parent membership. Existing row order,
VoiceOver labels/hints/traits/announcements, focus and toggle behavior are unchanged.
No schema, sync, purchase, signing, or protected migration/reset changes.

## Evidence and validation

A simulator diagnostic with 500 podcasts and 2,000 memberships compared the
legacy row scans with the production selection helper: approximately 0.554 seconds
versus 0.00124 seconds for the selected-folder set. Every selected podcast matched,
and reverse folder selections were also equivalent. This is a synthetic code-path
measurement, not a claim about on-device latency or a reported folder-picker hang.

Regression tests cover duplicates, missing endpoints, unrelated scopes, direct
versus inherited membership, add/remove, and newly created nested folders.
All 86 focused folder-picker, folder-logic and podcast-settings tests passed on
an iOS 26.5 simulator with Xcode 27. The UI regression also passed: open Manage
folders, create a folder, verify selected, toggle off, then toggle on. Physical
VoiceOver acceptance remains pending.

## Further audit leads

- QueueScreen.flatList reads the computed episodes array for every row's total
  count. Reusing the current render's array/count would avoid repeated QueueItem
  relationship walks. It must preserve full-queue positions while filtering.
- PodcastSettingsView.containingFolders computes each breadcrumb path repeatedly
  inside its sort comparator and again when rendering. Decorate-sort-render with
  one current path per folder could remove repeated parent-chain walks.
- Queue grouped rendering invokes groupedQueue/groupedQueueByFolder from the
  render path. Profile invalidation frequency and database work before introducing
  retained caches; incorrect invalidation could hide live Queue/folder changes.
- Directory description fetching may still load many feeds for broad searches.
  Demand-based loading needs careful VoiceOver value/action timing and global
  concurrency review; do not silently remove descriptions for later results.

Those leads are not implemented or presented as demonstrated phone bottlenecks.

## Phone checks for a later build

In a folder's Add podcasts picker, toggle several podcasts in and out; close and
reopen. In a podcast's Manage folders picker, toggle multiple nested folders and
create a folder. Confirm selected states, labels, announcements and focus match
existing behavior, changes persist, and rapid VoiceOver navigation stays responsive.
