import SwiftUI
import UIKit

/// Reports the window that actually hosts a SwiftUI scene. The active window,
/// rather than the process-wide scene list, owns transient player presentation.
struct KeyWindowProbe: UIViewRepresentable {
    let didChangeWindow: @MainActor (UIWindow?) -> Void

    func makeUIView(context: Context) -> WindowView {
        let view = WindowView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.didChangeWindow = didChangeWindow
        view.registerForTraitChanges([UITraitActiveAppearance.self]) {
            (view: WindowView, _) in
            view.didChangeWindow?(view.window)
        }
        return view
    }

    func updateUIView(_ view: WindowView, context: Context) {
        view.didChangeWindow = didChangeWindow
    }

    final class WindowView: UIView {
        var didChangeWindow: (@MainActor (UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            didChangeWindow?(window)
        }
    }
}

/// Avoid retaining a UIWindow through the SwiftUI root that it hosts.
final class WeakWindowReference {
    weak var value: UIWindow?
}
