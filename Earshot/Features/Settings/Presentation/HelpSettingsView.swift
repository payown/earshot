import SwiftUI

/// Settings → Help & About: contact/feedback and app info. Extracted from the
/// former single Settings form (Help section + About row folded together).
struct HelpSettingsView: View {
    var body: some View {
        Form {
            // No section header: the "Help & About" navigation title already
            // names the screen, so a matching header would be a redundant
            // VoiceOver heading stop.
            Section {
                NavigationLink("Inbox, Queue, and Downloads guide") { ListeningWorkflowGuide() }
                NavigationLink {
                    SendFeedbackView()
                } label: {
                    Label("Send Feedback", systemImage: "envelope")
                }
                .accessibilityHint("Email the Earshot team with feedback, bug reports, or ideas")

                // Tip jar (#636): a one-time, consumable purchase, available to
                // every user regardless of Earshot Plus entitlement. Placed
                // here rather than under the "Earshot Plus" section on the
                // Settings root — it is not part of that entitlement and
                // should not read as bundled with it.
                NavigationLink {
                    TipJarView()
                } label: {
                    Label("Leave a Tip", systemImage: "heart")
                }
                .accessibilityHint("Support Earshot development with a one-time tip")

                NavigationLink {
                    AboutView()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
                .accessibilityHint("App version, credits, and license")
            }
        }
        .navigationTitle("Help & About")
    }
}
