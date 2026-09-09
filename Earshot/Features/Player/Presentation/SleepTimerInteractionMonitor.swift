import SwiftUI
import UIKit

/// Observes the scene's window so sheets and tab content share one activity
/// source. It never recognizes a gesture, delays a touch, or adds a focus stop.
struct SleepTimerInteractionMonitor: UIViewRepresentable {
    let timer: SleepTimerController

    func makeUIView(context: Context) -> ActivityView {
        ActivityView()
    }

    func updateUIView(_ view: ActivityView, context: Context) {
        view.onInteraction = { [weak timer] in timer?.recordInteraction() }
        view.isMonitoring = timer.isActive && timer.resetsOnInteraction && !timer.endOfEpisode
    }

    static func dismantleUIView(_ view: ActivityView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class ActivityView: UIView {
        var onInteraction: (() -> Void)?
        var isMonitoring = false {
            didSet { recognizer.isEnabled = isMonitoring }
        }
        private weak var observedWindow: UIWindow?
        private let recognizer = ActivityGestureRecognizer()

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            recognizer.onInteraction = { [weak self] in self?.recordInteraction() }
            recognizer.isEnabled = false
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(accessibilityFocusChanged(_:)),
                               name: UIAccessibility.elementFocusedNotification, object: nil)
            center.addObserver(self, selector: #selector(textChanged(_:)),
                               name: UITextField.textDidChangeNotification, object: nil)
            center.addObserver(self, selector: #selector(textChanged(_:)),
                               name: UITextView.textDidChangeNotification, object: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard observedWindow !== window else { return }
            observedWindow?.removeGestureRecognizer(recognizer)
            observedWindow = window
            window?.addGestureRecognizer(recognizer)
        }

        func stopMonitoring() {
            observedWindow?.removeGestureRecognizer(recognizer)
            observedWindow = nil
            NotificationCenter.default.removeObserver(self)
            onInteraction = nil
        }

        private func recordInteraction() {
            guard isMonitoring, observedWindow?.windowScene?.activationState == .foregroundActive else { return }
            onInteraction?()
        }

        @objc private func accessibilityFocusChanged(_ notification: Notification) {
            // A focus departure (including locking the phone) is not activity.
            guard notification.userInfo?[UIAccessibility.focusedElementUserInfoKey] != nil else { return }
            recordInteraction()
        }

        @objc private func textChanged(_ notification: Notification) {
            guard let input = notification.object as? UIView,
                  input.window === observedWindow else { return }
            recordInteraction()
        }
    }
}

/// Stays possible until input ends, then fails. Other recognizers and controls
/// receive their normal events, including scrolling and long presses.
final class ActivityGestureRecognizer: UIGestureRecognizer {
    var onInteraction: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onInteraction?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        onInteraction?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onInteraction?()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onInteraction?()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onInteraction?()
        state = .failed
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .failed
    }
}
