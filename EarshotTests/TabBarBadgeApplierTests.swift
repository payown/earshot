import XCTest
import UIKit
@testable import Earshot

@MainActor
final class TabBarBadgeApplierTests: XCTestCase {
    private final class FixtureBadgeView: UIView {
        var hiddenWrites = 0
        override var accessibilityElementsHidden: Bool {
            get { super.accessibilityElementsHidden }
            set { hiddenWrites += 1; super.accessibilityElementsHidden = newValue }
        }
    }

    private final class FixtureLabel: UILabel {
        var elementWrites = 0
        override var isAccessibilityElement: Bool {
            get { super.isAccessibilityElement }
            set { elementWrites += 1; super.isAccessibilityElement = newValue }
        }
    }

    func testLatestCountsClearAndRestoreAfterUIKitRebuildsItems() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let tabs = UITabBarController()
        tabs.viewControllers = (0..<5).map { _ in UIViewController() }
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let badge = FixtureBadgeView()
        let label = FixtureLabel()
        label.isAccessibilityElement = true
        badge.addSubview(label)
        tabs.tabBar.addSubview(badge)
        TabBarBadgeApplier.apply(tabIndex: 0, count: 1)
        TabBarBadgeApplier.apply(tabIndex: 0, count: 42)
        TabBarBadgeApplier.apply(tabIndex: 1, count: 5)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tabs.tabBar.items?[0].badgeValue, "42")
        XCTAssertEqual(tabs.tabBar.items?[1].badgeValue, "5")
        XCTAssertTrue(badge.accessibilityElementsHidden)
        XCTAssertFalse(label.isAccessibilityElement)

        // Foreground/SwiftUI updates must leave a stable accessibility subtree
        // alone, including the delayed repair pass. Setter invocations can
        // invalidate VoiceOver's hierarchy even when their values are unchanged.
        badge.hiddenWrites = 0
        label.elementWrites = 0
        TabBarBadgeApplier.apply(tabIndex: 0, count: 42)
        TabBarBadgeApplier.apply(tabIndex: 1, count: 5)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(badge.hiddenWrites, 0)
        XCTAssertEqual(label.elementWrites, 0)

        TabBarBadgeApplier.apply(tabIndex: 0, count: 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(tabs.tabBar.items?[0].badgeValue)
        tabs.tabBar.items?[1].badgeValue = nil
        badge.accessibilityElementsHidden = false
        label.isAccessibilityElement = true
        TabBarBadgeApplier.apply(tabIndex: 1, count: 5)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tabs.tabBar.items?[1].badgeValue, "5")
        XCTAssertTrue(badge.accessibilityElementsHidden)
        XCTAssertFalse(label.isAccessibilityElement)

        // UIKit can create another badge after the initial layout pass.
        let delayed = FixtureBadgeView()
        delayed.isAccessibilityElement = true
        tabs.tabBar.addSubview(delayed)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(delayed.accessibilityElementsHidden)
        XCTAssertFalse(delayed.isAccessibilityElement)
    }
}
