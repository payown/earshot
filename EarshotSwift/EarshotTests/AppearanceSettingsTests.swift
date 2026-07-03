import XCTest
import SwiftUI
import SwiftData
@testable import Earshot

/// Pure-logic coverage for the Appearance preferences (#461): raw-value
/// round-trips (the persistence format), display names, theme → scheme /
/// contrast / legibility mappings, accent tint mappings including the
/// high-contrast resolution, the density 44pt floor, and the AppSettingsStore
/// typed helpers.
@MainActor
final class AppearanceSettingsTests: XCTestCase {

    // MARK: Raw values (persistence format — do not change without migration)

    func testThemeOverrideRawValuesAreStable() {
        XCTAssertEqual(ThemeOverride.followSystem.rawValue, "follow_system")
        XCTAssertEqual(ThemeOverride.light.rawValue, "light")
        XCTAssertEqual(ThemeOverride.dark.rawValue, "dark")
        XCTAssertEqual(ThemeOverride.highContrastLight.rawValue, "high_contrast_light")
        XCTAssertEqual(ThemeOverride.highContrastDark.rawValue, "high_contrast_dark")
    }

    func testAccentChoiceRawValuesAreStable() {
        XCTAssertEqual(AccentChoice.systemDefault.rawValue, "system_default")
        XCTAssertEqual(AccentChoice.blue.rawValue, "blue")
        XCTAssertEqual(AccentChoice.green.rawValue, "green")
        XCTAssertEqual(AccentChoice.orange.rawValue, "orange")
        XCTAssertEqual(AccentChoice.purple.rawValue, "purple")
        XCTAssertEqual(AccentChoice.red.rawValue, "red")
    }

    func testLayoutDensityRawValuesAreStable() {
        XCTAssertEqual(LayoutDensity.comfortable.rawValue, "comfortable")
        XCTAssertEqual(LayoutDensity.compact.rawValue, "compact")
    }

    func testAllCasesRoundTripThroughRawValues() {
        for theme in ThemeOverride.allCases {
            XCTAssertEqual(ThemeOverride(rawValue: theme.rawValue), theme)
        }
        for accent in AccentChoice.allCases {
            XCTAssertEqual(AccentChoice(rawValue: accent.rawValue), accent)
        }
        for density in LayoutDensity.allCases {
            XCTAssertEqual(LayoutDensity(rawValue: density.rawValue), density)
        }
    }

    // MARK: Display names

    func testDisplayNamesAreNonEmptyAndUnique() {
        let themeNames = ThemeOverride.allCases.map(\.displayName)
        let accentNames = AccentChoice.allCases.map(\.displayName)
        let densityNames = LayoutDensity.allCases.map(\.displayName)
        for name in themeNames + accentNames + densityNames {
            XCTAssertFalse(name.isEmpty)
        }
        XCTAssertEqual(Set(themeNames).count, themeNames.count)
        XCTAssertEqual(Set(accentNames).count, accentNames.count)
        XCTAssertEqual(Set(densityNames).count, densityNames.count)
    }

    // MARK: Theme mappings

    func testColorSchemeMapping() {
        XCTAssertNil(ThemeOverride.followSystem.colorScheme)
        XCTAssertEqual(ThemeOverride.light.colorScheme, .light)
        XCTAssertEqual(ThemeOverride.dark.colorScheme, .dark)
        XCTAssertEqual(ThemeOverride.highContrastLight.colorScheme, .light)
        XCTAssertEqual(ThemeOverride.highContrastDark.colorScheme, .dark)
    }

    func testHighContrastFlags() {
        XCTAssertFalse(ThemeOverride.followSystem.isHighContrast)
        XCTAssertFalse(ThemeOverride.light.isHighContrast)
        XCTAssertFalse(ThemeOverride.dark.isHighContrast)
        XCTAssertTrue(ThemeOverride.highContrastLight.isHighContrast)
        XCTAssertTrue(ThemeOverride.highContrastDark.isHighContrast)
    }

    /// High Contrast themes must be visibly different from plain Light/Dark, not
    /// no-ops: bold legibility is one of the differences. Non-HC themes return
    /// nil (don't touch) so a user's system Bold Text setting is never stripped.
    func testLegibilityWeightIsBoldOnlyForHighContrast() {
        for theme in ThemeOverride.allCases {
            if theme.isHighContrast {
                XCTAssertEqual(theme.legibilityWeight, .bold)
            } else {
                XCTAssertNil(theme.legibilityWeight)
            }
        }
    }

    // MARK: Accent mappings

    func testSystemDefaultAccentNeverTints() {
        for theme in ThemeOverride.allCases {
            XCTAssertNil(AccentChoice.systemDefault.tint(for: theme))
        }
        XCTAssertNil(AccentChoice.systemDefault.baseUIColor)
    }

    func testNamedAccentsAlwaysTint() {
        let named: [AccentChoice] = [.blue, .green, .orange, .purple, .red]
        for accent in named {
            XCTAssertNotNil(accent.baseUIColor)
            for theme in ThemeOverride.allCases {
                XCTAssertNotNil(accent.tint(for: theme))
            }
        }
    }

    func testBaseColorsAreTheSystemPalette() {
        XCTAssertEqual(AccentChoice.blue.baseUIColor, .systemBlue)
        XCTAssertEqual(AccentChoice.green.baseUIColor, .systemGreen)
        XCTAssertEqual(AccentChoice.orange.baseUIColor, .systemOrange)
        XCTAssertEqual(AccentChoice.purple.baseUIColor, .systemPurple)
        XCTAssertEqual(AccentChoice.red.baseUIColor, .systemRed)
    }

    /// The high-contrast resolution must produce the system's increased-contrast
    /// variant — a different color from the normal-contrast resolution in the
    /// same style. This is what makes an HC theme's accent visibly stronger.
    func testHighContrastResolutionDiffersFromNormalContrast() {
        for accent in [AccentChoice.blue, .green, .orange, .purple, .red] {
            guard let base = accent.baseUIColor else {
                return XCTFail("named accent missing base color")
            }
            for darkMode in [false, true] {
                let normalTraits = UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: darkMode ? .dark : .light),
                    UITraitCollection(accessibilityContrast: .normal),
                ])
                let normal = base.resolvedColor(with: normalTraits)
                let high = AccentChoice.highContrastResolved(base, darkMode: darkMode)
                XCTAssertNotEqual(
                    normal, high,
                    "\(accent) should have a distinct high-contrast variant (darkMode: \(darkMode))"
                )
            }
        }
    }

    /// Every accent row's chip has a color even for System Default, so the
    /// picker never shows an empty chip (the text label carries the meaning).
    func testSwatchColorExistsForEveryChoice() {
        for accent in AccentChoice.allCases {
            _ = accent.swatchColor  // must not trap; systemDefault falls back to accentColor
        }
        XCTAssertEqual(AccentChoice.systemDefault.swatchColor, .accentColor)
    }

    // MARK: Density

    func testComfortableLeavesRowHeightUntouched() {
        XCTAssertNil(LayoutDensity.comfortable.minListRowHeight)
    }

    /// Compact must never take a row below the 44pt touch-target floor.
    func testCompactRowHeightMeetsTouchTargetFloor() {
        guard let height = LayoutDensity.compact.minListRowHeight else {
            return XCTFail("compact should set an explicit min row height")
        }
        XCTAssertGreaterThanOrEqual(height, Spacing.minTouchTarget)
        XCTAssertGreaterThanOrEqual(height, 44)
    }

    // MARK: AppSettingsStore typed helpers

    func testStoreReturnsDefaultsWhenUnset() {
        let store = AppSettingsStore(context: TestStore.freshContext())
        XCTAssertEqual(store.themeOverride(), .followSystem)
        XCTAssertEqual(store.accentChoice(), .systemDefault)
        XCTAssertEqual(store.layoutDensity(), .comfortable)
    }

    func testStoreRoundTripsAppearanceValues() {
        let store = AppSettingsStore(context: TestStore.freshContext())
        store.setThemeOverride(.highContrastDark)
        store.setAccentChoice(.purple)
        store.setLayoutDensity(.compact)
        XCTAssertEqual(store.themeOverride(), .highContrastDark)
        XCTAssertEqual(store.accentChoice(), .purple)
        XCTAssertEqual(store.layoutDensity(), .compact)
    }

    func testStoreFallsBackToDefaultsOnGarbageValues() {
        let store = AppSettingsStore(context: TestStore.freshContext())
        store.setRawValue("mauve", for: SettingsKey.themeOverride)
        store.setRawValue("chartreuse", for: SettingsKey.accentColor)
        store.setRawValue("cozy", for: SettingsKey.layoutDensity)
        XCTAssertEqual(store.themeOverride(), SettingsDefault.themeOverride)
        XCTAssertEqual(store.accentChoice(), SettingsDefault.accentColor)
        XCTAssertEqual(store.layoutDensity(), SettingsDefault.layoutDensity)
    }

    func testSettingsStoreLoadsAndPersistsAppearance() {
        let context = TestStore.freshContext()
        let backing = AppSettingsStore(context: context)
        backing.setThemeOverride(.dark)
        backing.setAccentChoice(.green)
        backing.setLayoutDensity(.compact)

        let settings = SettingsStore()
        settings.configure(context: context)
        XCTAssertEqual(settings.themeOverride, .dark)
        XCTAssertEqual(settings.accentColor, .green)
        XCTAssertEqual(settings.layoutDensity, .compact)

        settings.themeOverride = .highContrastLight
        settings.accentColor = .red
        settings.layoutDensity = .comfortable
        XCTAssertEqual(backing.themeOverride(), .highContrastLight)
        XCTAssertEqual(backing.accentChoice(), .red)
        XCTAssertEqual(backing.layoutDensity(), .comfortable)
    }
}
