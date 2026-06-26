import SwiftUI
import UIKit

/// Pure formatting for the Inbox tab badge. Kept separate from the UIKit bridge
/// so the visible/spoken strings have one source of truth and can be unit-tested
/// without a tab bar (mirrors the project's logic-test convention).
enum TabBadgeFormat {
    /// The visible badge string (the red bubble). `nil` clears the bubble.
    static func badgeText(_ count: Int) -> String? {
        count > 0 ? "\(count)" : nil
    }

    /// The value VoiceOver folds into the tab's single announcement, e.g.
    /// "Inbox, 5 new episodes, tab, 1 of 5". Worded "new episodes" to match the
    /// app's own inbox language (InboxScreen). `nil` when the inbox is empty.
    static func accessibilityValue(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) new \(count == 1 ? "episode" : "episodes")"
    }
}

/// Writes a native `UITabBarItem.badgeValue` onto the app's tab bar so VoiceOver
/// folds the count into the tab's single announcement.
///
/// SwiftUI's `.badge(Int)` on a `.tabItem` exposes the red bubble as its OWN
/// accessibility element in addition to the tab, so flicking past the tab
/// announces the number a second time. Setting `badgeValue` at the UIKit level
/// keeps the visible bubble but produces no extra element — UIKit reads the badge
/// as part of the tab's value ("Inbox, N unread items").
///
/// The view itself renders nothing; it only needs to be in the hierarchy so its
/// `updateUIView` runs whenever `count` changes. It finds the tab bar by scanning
/// the connected window scenes, which assumes the app has a single
/// `UITabBarController` (true for Earshot's root `TabView`).
struct TabBarBadgeApplier: UIViewRepresentable {
    /// Zero-based index of the tab to badge (Inbox is 0 in RootView's TabView).
    let tabIndex: Int
    /// Count to show. Zero or negative clears the badge entirely.
    let count: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        Self.apply(tabIndex: tabIndex, count: count)
    }

    /// Sets (or clears) the native badge on the tab at `tabIndex`. Deferred one
    /// runloop so the tab bar exists on first launch. Shared by `updateUIView`
    /// and the selection-change re-assert in RootView.
    static func apply(tabIndex: Int, count: Int) {
        DispatchQueue.main.async {
            guard let tabBar = findTabBar(),
                  let items = tabBar.items,
                  tabIndex >= 0, tabIndex < items.count else { return }
            let item = items[tabIndex]
            item.badgeValue = TabBadgeFormat.badgeText(count)
            item.accessibilityValue = TabBadgeFormat.accessibilityValue(count)
        }
    }

    /// Locates the app's single `UITabBar`. Earshot has exactly one
    /// `UITabBarController` (the root `TabView`), so the first match is correct.
    private static func findTabBar() -> UITabBar? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let root = window.rootViewController,
                   let bar = tabBar(in: root) {
                    return bar
                }
            }
        }
        return nil
    }

    private static func tabBar(in controller: UIViewController) -> UITabBar? {
        if let tbc = controller as? UITabBarController { return tbc.tabBar }
        for child in controller.children {
            if let found = tabBar(in: child) { return found }
        }
        if let presented = controller.presentedViewController {
            return tabBar(in: presented)
        }
        return nil
    }
}
