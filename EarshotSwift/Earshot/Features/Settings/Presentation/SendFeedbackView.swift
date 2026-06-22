import SwiftUI
import UIKit
import MessageUI

/// Settings → Send Feedback (PRD 12, issue #392).
///
/// Opens a pre-filled mail composer to `beta@payown.media`. The user can choose
/// to attach an anonymized system-info block (app version, build, iOS version,
/// device model — nothing personal). When no Mail account is configured the
/// screen falls back to a `mailto:` URL; if that can't be opened either, it
/// surfaces a calm in-line message and logs the situation. Never crashes.
@MainActor
struct SendFeedbackView: View {
    @Environment(\.openURL) private var openURL

    /// Opt-in defaults to ON: the info is anonymized and makes bug reports far
    /// more useful, but it stays clearly optional and user-controllable, in line
    /// with Earshot's minimum-data ethos.
    @State private var includeSystemInfo = true

    @State private var showingMailComposer = false
    @State private var fallbackMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Send feedback, bug reports, or feature ideas straight to the Earshot team.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Include system info to help debugging", isOn: $includeSystemInfo)
                    .accessibilityHint("Adds your app version, iOS version, and device model. Anonymized, no personal data.")
            } footer: {
                Text("Adds app version, iOS version, and device model. Anonymized — no names, accounts, or listening history.")
            }

            Section {
                Button {
                    sendFeedback()
                } label: {
                    Label("Compose feedback email", systemImage: "envelope")
                }
                .accessibilityHint("Opens an email to beta at payown dot media")
            }

            if let fallbackMessage {
                Section {
                    Text(fallbackMessage)
                        .font(.callout)
                        .foregroundStyle(AppColor.error)
                        .accessibilityLabel("Can't send mail. \(fallbackMessage)")
                }
            }
        }
        .navigationTitle("Send Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingMailComposer) {
            MailComposeView(
                recipients: [FeedbackComposer.recipient],
                subject: FeedbackComposer.defaultSubject,
                body: composedBody
            ) {
                showingMailComposer = false
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Body construction

    private var composedBody: String {
        let info = includeSystemInfo ? FeedbackComposer.systemInfoBlock(
            appVersion: AppInfo.version,
            build: AppInfo.build,
            iosVersion: UIDevice.current.systemVersion,
            deviceModel: Self.deviceModelIdentifier
        ) : nil
        return FeedbackComposer.body(systemInfo: info)
    }

    // MARK: Actions

    private func sendFeedback() {
        fallbackMessage = nil

        if MFMailComposeViewController.canSendMail() {
            showingMailComposer = true
            return
        }

        // No configured Mail account — fall back to a mailto: URL.
        guard let url = FeedbackComposer.mailtoURL(
            to: FeedbackComposer.recipient,
            subject: FeedbackComposer.defaultSubject,
            body: composedBody
        ) else {
            AppLog.data.error("Send Feedback: could not build mailto URL")
            showFallbackMessage()
            return
        }

        openURL(url) { accepted in
            if !accepted {
                AppLog.data.error("Send Feedback: no app could handle mailto URL")
                showFallbackMessage()
            }
        }
    }

    private func showFallbackMessage() {
        let message = "No email app is set up on this device. You can reach us at \(FeedbackComposer.recipient)."
        fallbackMessage = message
        Announcer.announce(message)
    }

    // MARK: Anonymized device info

    /// The hardware model identifier (e.g. "iPhone16,2"). On the simulator the
    /// real device model is exposed via the `SIMULATOR_MODEL_IDENTIFIER`
    /// environment variable; `utsname` reports the host architecture there.
    private static var deviceModelIdentifier: String {
        if let simulator = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulator
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}
