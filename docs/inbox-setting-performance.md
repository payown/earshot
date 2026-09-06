# Inbox limit adjustment responsiveness

Michael reported a one-to-two-second slowdown immediately after changing a
podcast's Inbox limit from unlimited to one in direct-device build 259. This
is distinct from refresh-time limit enforcement, which he confirmed works.

## Changes

- Retain immediate main-context persistence and the existing picker semantics.
- Publish scalar settings edits with their feed URL and a settings-only marker.
  The cloud coordinator updates that subscription without scheduling a full
  reconciliation afterward. Untagged graph changes and remote imports retain
  their existing reconciliation behavior.
- Ignore settings-only notifications in Folder detail: they cannot change its
  membership snapshot. Other subscription notifications still reload it.
- Query folder memberships for the selected podcast, rather than materializing
  other podcasts' memberships. Reuse that result within the settings section.
- Restrict legacy setting-key alias lookups to their namespace. Preserve
  canonicalization and duplicate repair, including older feed URL spellings.

These are code-backed reductions in unnecessary work, not a measured device
latency improvement. No delayed writes, actor transfer of SwiftData models,
schema change, accessibility semantics change, or reset behavior is introduced.

## Verification

Regression coverage includes durable cap persistence, scoped notifications,
legacy aliases among unrelated settings, folder membership deduplication, and
targeted cloud projection. The first local run exposed that the old targeted
notification still scheduled full reconciliation; the corrected test seeds its
initial graph without a pending reconciliation and uses the actual settings
save path.

Final local validation on September 6, 2026 passed 201 tests, with one skipped
and zero failures, including the full CloudProjectionCoordinatorTests suite.
Result: `/tmp/earshot-inbox-setting-performance-final.xcresult`.
Signed Release build and strict signature verification passed. Version 1.2.2
build 260 (command-line version override) was installed directly over Michael's
existing app via Wi-Fi, without a data reset or diagnostic logging. Source:
`fd31290`. Physical responsiveness acceptance remains pending.

Device acceptance: in the same podcast, change unlimited to one, immediately
flick to the next control, and repeat in both directions. Check spoken value,
focus, and responsiveness; reopen settings to verify persistence. Refresh then
confirms that the Inbox count cap still applies without deleting older downloads.
