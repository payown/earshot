import SwiftUI
import MessageUI

/// Wraps `MFMailComposeViewController` (MessageUI, a system framework) so the
/// Send Feedback screen can present a pre-filled mail composer from SwiftUI.
///
/// The compose-result callback dismisses the sheet. Callers should only present
/// this when `MFMailComposeViewController.canSendMail()` is true; otherwise use
/// the `mailto:` fallback in ``FeedbackComposer``.
@MainActor
struct MailComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String

    /// Called after the user sends or cancels, so the presenter can dismiss.
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(recipients)
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            if let error {
                AppLog.data.error("Mail compose failed: \(error.localizedDescription, privacy: .public)")
            }
            onFinish()
        }
    }
}
