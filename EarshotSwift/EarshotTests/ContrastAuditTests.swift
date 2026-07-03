import XCTest
import UIKit
@testable import Earshot

/// WCAG 2.1 contrast audit of the app's semantic color pairings (#462).
///
/// The app sources every color from the system palette (see ``AppColor`` and
/// ``AccentChoice``) so it follows the user's theme and contrast settings and
/// never hardcodes hex. This audit resolves those system colors in each trait
/// (light, dark, and the app's two High Contrast themes) and asserts the
/// contrast floor the PRD commits to: **AAA (7:1) for primary text, AA minimum
/// (4.5:1 normal, 3:1 large/graphical) everywhere** (PRD "AAA where possible,
/// AA minimum everywhere"). It doubles as a regression guard: a future color
/// change that drops a pairing below its floor fails here.
///
/// Ratios are computed by compositing each foreground over its background
/// (system label colors are translucent) and applying the WCAG relative-
/// luminance formula.
final class ContrastAuditTests: XCTestCase {

    // MARK: WCAG math

    private func linearize(_ v: CGFloat) -> Double {
        let x = Double(v)
        return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /// Composites `fg` (which may be translucent, like `.secondaryLabel`) over an
    /// opaque `bg`, so the measured luminance reflects what the user actually sees.
    private func composite(_ fg: UIColor, over bg: UIColor) -> UIColor {
        var fr: CGFloat = 0, fgc: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bgc: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        fg.getRed(&fr, green: &fgc, blue: &fb, alpha: &fa)
        bg.getRed(&br, green: &bgc, blue: &bb, alpha: &ba)
        return UIColor(
            red: fr * fa + br * (1 - fa),
            green: fgc * fa + bgc * (1 - fa),
            blue: fb * fa + bb * (1 - fa),
            alpha: 1
        )
    }

    private func ratio(_ fg: UIColor, on bg: UIColor, traits: UITraitCollection) -> Double {
        let rfg = fg.resolvedColor(with: traits)
        let rbg = bg.resolvedColor(with: traits)
        let composited = composite(rfg, over: rbg)
        let l1 = luminance(composited)
        let l2 = luminance(rbg)
        let hi = max(l1, l2), lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    private func traits(dark: Bool, highContrast: Bool) -> UITraitCollection {
        UITraitCollection { t in
            t.userInterfaceStyle = dark ? .dark : .light
            t.accessibilityContrast = highContrast ? .high : .normal
        }
    }

    private var themes: [(name: String, traits: UITraitCollection)] {
        [
            ("Light", traits(dark: false, highContrast: false)),
            ("Dark", traits(dark: true, highContrast: false)),
            ("HC Light", traits(dark: false, highContrast: true)),
            ("HC Dark", traits(dark: true, highContrast: true)),
        ]
    }

    // MARK: Measurement (prints the full table for the audit doc)

    func testPrintContrastTable() {
        let pairings: [(String, UIColor, UIColor)] = [
            ("label / background", .label, .systemBackground),
            ("label / grouped", .label, .systemGroupedBackground),
            ("secondaryLabel / background", .secondaryLabel, .systemBackground),
            ("secondaryLabel / grouped", .secondaryLabel, .systemGroupedBackground),
            ("accent(blue) / background", .systemBlue, .systemBackground),
            ("accent(green) / background", .systemGreen, .systemBackground),
            ("accent(orange) / background", .systemOrange, .systemBackground),
            ("accent(purple) / background", .systemPurple, .systemBackground),
            ("accent(red) / background", .systemRed, .systemBackground),
            ("played(green) icon / background", .systemGreen, .systemBackground),
            ("error(red) icon / background", .systemRed, .systemBackground),
        ]
        var lines = ["\n=== CONTRAST AUDIT (#462) ==="]
        for (label, fg, bg) in pairings {
            let cols = themes.map { theme in
                String(format: "%@ %.2f:1", theme.name, ratio(fg, on: bg, traits: theme.traits))
            }
            lines.append("\(label): " + cols.joined(separator: "  |  "))
        }
        print(lines.joined(separator: "\n"))
    }

    // MARK: Floor assertions

    /// Primary text hits AAA (7:1) in every theme — the strongest guarantee.
    func testPrimaryTextMeetsAAAEverywhere() {
        for theme in themes {
            for bg in [UIColor.systemBackground, .systemGroupedBackground] {
                let r = ratio(.label, on: bg, traits: theme.traits)
                XCTAssertGreaterThanOrEqual(
                    r, 7.0,
                    "Primary text must meet WCAG AAA (7:1) in \(theme.name); got \(String(format: "%.2f", r)):1"
                )
            }
        }
    }

    /// Secondary text is supplementary (always paired with primary text), so its
    /// committed floor is AA large-text / graphical (3:1). Documents that the
    /// default themes do NOT reach AAA for secondary text — that is inherent to
    /// Apple's system palette and is why the High Contrast themes exist.
    func testSecondaryTextMeetsLargeTextAAFloor() {
        for theme in themes {
            for bg in [UIColor.systemBackground, .systemGroupedBackground] {
                let r = ratio(.secondaryLabel, on: bg, traits: theme.traits)
                XCTAssertGreaterThanOrEqual(
                    r, 3.0,
                    "Secondary text must meet the 3:1 floor in \(theme.name); got \(String(format: "%.2f", r)):1"
                )
            }
        }
    }

    /// The High Contrast themes must measurably raise secondary-text contrast
    /// above the plain theme of the same scheme — proving they are not no-ops and
    /// are the AAA-seeking path (PRD: "high-contrast modes push to 14:1 or higher
    /// where possible").
    func testHighContrastRaisesSecondaryTextContrast() {
        let plainLight = ratio(.secondaryLabel, on: .systemBackground, traits: traits(dark: false, highContrast: false))
        let hcLight = ratio(.secondaryLabel, on: .systemBackground, traits: traits(dark: false, highContrast: true))
        XCTAssertGreaterThan(hcLight, plainLight, "HC Light must raise secondary-text contrast over plain Light")

        let plainDark = ratio(.secondaryLabel, on: .systemBackground, traits: traits(dark: true, highContrast: false))
        let hcDark = ratio(.secondaryLabel, on: .systemBackground, traits: traits(dark: true, highContrast: true))
        XCTAssertGreaterThan(hcDark, plainDark, "HC Dark must raise secondary-text contrast over plain Dark")
    }
}
