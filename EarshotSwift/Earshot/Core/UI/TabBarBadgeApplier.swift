import SwiftUI
import UIKit

/// Pure formatting for the Inbox tab badge. Kept separate from the UIKit bridge
/// so the visible string has one source of truth and can be unit-tested without a
/// tab bar (mirrors the project's logic-test convention).
enum TabBadgeFormat {
    /// The visible badge string (the red bubble). `nil` clears the bubble.
    static func badgeText(_ count: Int) -> String? {
        count > 0 ? "\(count)" : nil
    }
}

/// Sets the Inbox tab's unread count as a native `UITabBarItem.badgeValue` (the
/// red bubble) and suppresses the badge's duplicate VoiceOver announcement.
///
/// Why this exists: on iOS 26/27 a tab badge — whether from SwiftUI's `.badge`
/// or UIKit's `badgeValue` — is rendered as `BadgeContainerView` ->
/// `_UIBarBadgeView` -> `UILabel`, and that inner `UILabel` has
/// `isAccessibilityElement == true`. So VoiceOver stops on a standalone "163"
/// element *in addition to* the tab button, which already announces
/// "Inbox, 163 items". The duplicate is what users heard when flicking from the
/// Inbox tab toward Queue. We can't suppress it from SwiftUI because the badge
/// lives in UIKit's private tab-bar hierarchy, so we reach in and mark the badge
/// subtree `accessibilityElementsHidden` (the bubble stays visible). The tab
/// button keeps UIKit's native "Inbox, N items" announcement — attempts to
/// override it to "N new episodes" don't stick (UIKit re-derives the value on a
/// later layout pass), so we leave the reliable native string.
///
/// The view itself renders nothing; it only needs to be in the hierarchy so its
/// `updateUIView` runs whenever `count` changes. It finds the tab bar by scanning
/// the connected window scenes, which assumes the app has a single
/// `UITabBarController` (true for Earshot's root `TabView`).
struct TabBarBadgeApplier: UIViewRepresentable {
    /// Zero-based index of the tab to badge (Inbox is 0, Queue is 1 in RootView's
    /// TabView). UIKit folds the badge into that tab's VoiceOver announcement
    /// ("Inbox, N items" / "Queue, N items") — see #491.
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

    /// Sets (or clears) the native badge on the tab at `tabIndex`, then hides the
    /// badge subtree from accessibility. Deferred one runloop so the tab bar
    /// exists on first launch. Shared by `updateUIView` and the selection-change
    /// re-assert in RootView.
    static func apply(tabIndex: Int, count: Int) {
        DispatchQueue.main.async {
            guard let tabBar = findTabBar(),
                  let items = tabBar.items,
                  tabIndex >= 0, tabIndex < items.count else { return }
            items[tabIndex].badgeValue = TabBadgeFormat.badgeText(count)
            // Force the badge view to exist this runloop so the suppression runs
            // before VoiceOver can read it.
            tabBar.layoutIfNeeded()
            hideBadgeAccessibility(in: tabBar)
            // Re-apply after layout settles: on first launch (and when the count
            // changes) UIKit can (re)create the badge subtree a beat later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                hideBadgeAccessibility(in: tabBar)
            }
        }
    }

    /// Recursively marks any tab-bar badge subtree (`BadgeContainerView` /
    /// `_UIBarBadgeView` and descendants) hidden from assistive tech, so the
    /// standalone count element disappears while the red bubble stays visible.
    /// Matched by private class-name substring, so it fails safe: if Apple
    /// renames the views, nothing is hidden and we're back to the (non-crashing)
    /// duplicate, never a broken tab bar.
    private static func hideBadgeAccessibility(in root: UIView) {
        if String(describing: type(of: root)).contains("Badge") {
            root.accessibilityElementsHidden = true
            setIsAccessibilityElementFalse(in: root)
            return
        }
        for sub in root.subviews { hideBadgeAccessibility(in: sub) }
    }

    private static func setIsAccessibilityElementFalse(in view: UIView) {
        view.isAccessibilityElement = false
        for sub in view.subviews { setIsAccessibilityElementFalse(in: sub) }
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
