import SwiftUI

/// Settings → Help & About: contact/feedback and app info. Extracted from the
/// former single Settings form (Help section + About row folded together).
struct HelpSettingsView: View {
    var body: some View {
        Form {
            Section("Help & About") {
                NavigationLink {
                    SendFeedbackView()
                } label: {
                    Label("Send Feedback", systemImage: "envelope")
                }
                .accessibilityHint("Email the Earshot team with feedback, bug reports, or ideas")

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
