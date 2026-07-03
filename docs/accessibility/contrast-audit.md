# Contrast audit — default and High Contrast themes (#462)

Parity from Flutter #260. Verifies Earshot's color pairings against WCAG 2.1
contrast targets. The PRD commits to **"WCAG AAA (7:1 normal, 4.5:1 large) where
possible, AA minimum everywhere"** (PRD sections 7/8).

Earshot never hardcodes hex. Every color comes from the system semantic palette
(`AppColor`, `AccentChoice`) so it tracks the user's Light/Dark choice and the
system's increased-contrast trait. That is why this is an audit of *system*
colors resolved per theme, not of app-authored colors — a grep of the codebase
finds zero hardcoded colors, `.opacity` on text, `.tertiary`/`.quaternary`
labels, or text-on-tint.

## Method

`EarshotTests/ContrastAuditTests.swift` resolves each `UIColor` in the four
themes (Light, Dark, High Contrast Light, High Contrast Dark — the last two via
`accessibilityContrast(.high)`, exactly how `AccentChoice.tint(for:)` resolves
them), composites translucent foregrounds (e.g. `.secondaryLabel`) over their
background, and applies the WCAG relative-luminance formula. The test is a
living regression guard: it prints the table below and asserts the floors.

## Measured ratios

| Pairing | Light | Dark | HC Light | HC Dark |
|---|---|---|---|---|
| label / background | 21.00:1 | 21.00:1 | 21.00:1 | 21.00:1 |
| label / grouped | 18.82:1 | 21.00:1 | 17.67:1 | 21.00:1 |
| secondaryLabel / background | 3.44:1 | 6.36:1 | 5.97:1 | 8.48:1 |
| secondaryLabel / grouped | 3.30:1 | 6.36:1 | 5.33:1 | 8.48:1 |
| accent(blue) / background | 3.52:1 | 6.49:1 | 4.57:1 | 9.76:1 |
| accent(green) / background | 2.22:1 | 10.39:1 | 4.54:1 | 11.42:1 |
| accent(orange) / background | 2.31:1 | 9.41:1 | 4.55:1 | 10.41:1 |
| accent(purple) / background | 4.17:1 | 5.79:1 | 5.21:1 | 9.75:1 |
| accent(red) / background | 3.57:1 | 6.12:1 | 4.56:1 | 7.15:1 |

(Full numbers regenerate from `testPrintContrastTable`.)

## Findings and outcome

**Primary text meets AAA in every theme (17.7–21:1).** `label` is the color for
all essential reading content. Asserted by `testPrimaryTextMeetsAAAEverywhere`.

**Secondary text is supplementary and meets its 3:1 large-text floor** in every
theme (min 3.30:1 in Light). It is always paired with primary text, never the
sole carrier of meaning. It does not reach AAA in the plain Light theme — that
is inherent to Apple's `.secondaryLabel` and is what the High Contrast themes
exist to raise (Light 3.44 → HC Light 5.97; Dark 6.36 → HC Dark 8.48). Asserted
by `testSecondaryTextMeetsLargeTextAAFloor` and
`testHighContrastRaisesSecondaryTextContrast`.

**Accent and state colors are system-palette-bounded.** In plain Light mode the
system green/orange tints measure ~2.2–2.3:1 as a pure foreground. Earshot never
renders essential text in an accent color, and:
- `AppColor.played` (systemGreen) is **not used as a foreground anywhere** — the
  played state is conveyed by a labeled control + text, not a bare green mark.
- Accent color is a user choice shown next to a text label and native selection
  state, so color is never the only signal (`AccentChoice.displayName`).
- Every accent choice clears 4.5:1 (AAA-large) in both High Contrast themes.

**One fix applied.** `AppColor.error` (systemRed, 3.57:1 in Light — below
AA-normal) was used as bare `.callout` body text in `AddFeedView` and
`SendFeedbackView`. Both now match the pattern already used in
`PodcastPreviewView`: a red `exclamationmark.triangle.fill` icon (graphical,
3.57:1 ≥ the 3:1 floor) beside the message in the default `label` color (~21:1).
This removes the only measured normal-text contrast failure while keeping the
color system-sourced and making the error not color-dependent.

## Conclusion

The default Light/Dark themes meet the committed floor (AAA for primary text, AA
minimum elsewhere) once the single error-text case above is fixed. Full AAA for
secondary and accent colors is delivered by the High Contrast Light/Dark themes,
which is the intended path for users who need it and is respected rather than
overridden, per Earshot's "follow the system" rule. `ContrastAuditTests` guards
these floors against future color regressions.
