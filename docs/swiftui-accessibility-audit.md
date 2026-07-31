# Earshot (SwiftUI) — F16 Polish & Accessibility Audit

Final accessibility and performance sweep for the native SwiftUI rebuild
(`swift` branch), covering PRD 7 (accessibility) and PRD 8 (performance). Earshot
is accessibility-first: blind and low-vision screen reader users are the primary
audience, so VoiceOver correctness is the highest bar.

## Scope

Every screen built in F1–F15 was reviewed with the `mobile-accessibility` agent,
either at the time it was built or in this final sweep. This document is the
consolidated record.

## VoiceOver audit

Each feature was reviewed against: focus order, label/role/hint correctness,
custom-action reachability (the Actions rotor), state announcements, and the
"no empty `accessibilityValue`" rule (an empty value registers a node VoiceOver
reads as a pause).

| Area | Reviewed | Notable fixes |
| --- | --- | --- |
| Folders (F11) | yes | picker `.isToggle` state announce; EditButton so member reorder is reachable; author in row labels |
| Bookmarks (F12) | yes | `@State`-backed list refresh after rotor delete; "no episode playing" spoken; `ViewThatFits` so 4 transport buttons keep 44pt |
| Stats (F13) | yes | announce new total on period change; deferred post-delete announce; disabled-export hint; empty state leads |
| Chapters + sleep timer (F14) | yes | coarse spoken countdown (no per-second spam); `.isSelected` current chapter (no empty value node); explicit button trait |
| Onboarding + tips (F15) | yes | only the current page is reachable in the paged TabView; focus moves to each new page heading with position spoken; delayed tip announce |
| Inbox | yes (F16) | empty-state made a focusable element; focus request delayed until the list collapses |
| Queue | yes (F16) | group header trait moved onto the title `Text` so the Play-group button stays a distinct element |
| Downloads | yes (F16) | visible Restore button hidden from the combined row (action stays on the rotor); day/days pluralization in the value |
| Settings | yes (F16) | removed per-toggle hints that duplicated section footers (VoiceOver was reading the same sentence twice) |
| Episode row / list / show notes | yes (F16) | clean — no defects |

## Dynamic Type

- All text uses semantic `Font` styles (`.headline`, `.body`, `.caption`, …) —
  no hardcoded sizes — so everything scales with the user's setting.
- No essential text is pinned to `lineLimit(1)`; titles use `lineLimit(2)` where
  truncation is cosmetic only.
- The Now Playing bar reflows from a single row to title-over-controls via
  `ViewThatFits` at the largest accessibility sizes, so its four transport
  buttons never clip below their 44pt targets.
- No fixed-height containers around growing text were found.

## Reduce Motion

- A shared `Motion` helper (`Motion.preferred(_:)` / `Motion.isReduced`) gates
  animations.
- The only explicit animations in the app — the onboarding page transitions and
  the contextual-tip banner show/hide — now run through `Motion.preferred`, so
  they become instant when Reduce Motion is on.

## Touch targets

- Interactive elements are `List`/`Form` rows, `NavigationLink`s, toolbar items,
  and `Button`s — all system-sized to at least 44pt.
- Custom transport buttons set an explicit `minWidth/minHeight: 44` frame with a
  `contentShape(Rectangle())` hit area; the tip dismiss button does the same.

## Color is never the only signal

- Played state: icon + "Played" text + color.
- Current chapter: filled glyph + `.isSelected` trait + color.
- Sleep timer active: moon glyph + a "Sleep timer on" accessibility value.
- Disabled actions: the native "dimmed" trait + an explanatory hint.

## Performance

- Fixed an O(n²) fetch in `FolderRepository.unfiledPodcasts()` that re-fetched
  every membership once per podcast; it now fetches memberships once and tests
  set membership.
- Lists use `List`/`ForEach` over SwiftData `@Query` results (lazy rendering);
  no eager `Array(...)` materialization of large result sets in view bodies.
- Listening-session recording flushes one row per ~30s of playback (not per
  tick) and filters out seeks, so history stays bounded on heavy use.

## Deferred (tracked)

- **Audio-enhancement DSP** (skip silence / voice boost / mono, F14) — needs an
  `MTAudioProcessingTap` that can't be device-verified in CI; tracked on #349.

## Tests

189 unit tests pass (`xcodebuild test`, iPhone 17 simulator). Coverage spans the
data model graph, every feature repository, and the pure logic helpers
(chapters, sleep timer, stats, folders, bookmarks, tips).
