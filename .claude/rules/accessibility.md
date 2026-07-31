# Accessibility rules (SwiftUI)

Earshot exists to serve screen reader users. Michael is blind and uses
VoiceOver. Accessibility is the highest priority and the acceptance bar, not a
review step. Treat every UI as VoiceOver-first: design the spoken/keyboard path
first, then layer visuals on top.

The `earshot-accessibility` agent is a required gate on every PR that touches
SwiftUI views. The deep audit lives in `docs/swiftui-accessibility-audit.md`.

## Mandatory for every view

1. **Every interactive control has a correct accessible name.**
   - Prefer native controls (`Button`, `Toggle`, `Slider`, `Stepper`, `List`,
     `NavigationLink`) — they carry correct roles/traits for free. Override only
     when the default is wrong.
   - Icon-only controls: give a real `.accessibilityLabel("…")`. Never ship a
     control whose only name is an SF Symbol.
   - Decorative images/icons: `Image(decorative:)` or
     `.accessibilityHidden(true)` so they are not focus stops.

2. **Label / Value / Hint / Traits are used for what they mean.**
   - `.accessibilityLabel` = what it is. `.accessibilityValue` = its current
     state ("1.5x", "Played"). `.accessibilityHint` = what activating it does,
     only when non-obvious. `.accessibilityAddTraits`/`removeTraits` for
     `.isButton`, `.isSelected`, `.isHeader`, etc.
   - Combine a composed row into one element with
     `.accessibilityElement(children: .combine)` (or `.ignore` + explicit
     label) so VoiceOver reads one coherent thing, not five fragments.

3. **Quick Actions map to the VoiceOver actions rotor.** Expose per-item actions
   with `.accessibilityAction(named:)` and keep the user's configured order. The
   first configured action is the default activation. See `QuickActionsRotor`.

4. **Focus is managed deliberately after mutations.** Use
   `@AccessibilityFocusState` to move focus to a stable anchor after rows are
   moved/removed; never strand focus on a deleted element. Don't steal focus on
   routine updates.

5. **Announce meaningful change, stay quiet otherwise.** Use the app's Announcer
   for results the user must know ("Moved 3 episodes to News", "Playing",
   "Speed 1.5x"). Not for routine list updates.

6. **Color is never the only signal.** Pair every color-coded state (played,
   selected, error, downloaded) with an icon and a spoken label/value.

7. **Dynamic Type + touch targets.** Use semantic `Font`/text styles; never a
   hardcoded point size. Verify nothing clips at the largest accessibility size.
   Every control ≥ 44pt.

8. **Reduce Motion + system settings.** Honor `accessibilityReduceMotion`
   (instant transitions) and never override the user's theme, contrast, or type
   size. Earshot reads from the system, never imposes.

9. **Focus order matches visual order.** Fix ordering with
   `.accessibilitySortPriority` only when necessary, and document why.

## Refactors

Refactors must preserve spoken labels, values, traits, rotor actions, and focus
behavior **byte-for-byte** unless Michael explicitly approves a semantics
change. Do not touch accessibility semantics, `SettingsReset`, or purchase UI
without sign-off (see `AGENTS.md`).

## Testing requirements

- Every new screen has a test asserting its accessibility labels/values.
- Every UI PR includes a manual VoiceOver test note ("Tested with VoiceOver on
  iOS 18, all actions reachable via swipe and rotor").
- `earshot-accessibility` run and findings resolved before merge.
- When in doubt, test with VoiceOver on a physical device before merging.

## Patterns to avoid

- SF Symbol as the only label; `.help()` tooltip as the only name.
- Custom gesture-only controls with no accessible action alternative.
- Reading text aloud yourself; let VoiceOver do it.
- Hiding a still-interactive element from accessibility (`.accessibilityHidden`
  on something the user must reach).
- Splitting one logical row into many focus stops with no combined element.
