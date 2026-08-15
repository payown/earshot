import SwiftUI

/// Settings → Privacy: the plain-language "no data collected" statement and the
/// hosted policy links (#463). Extracted from the former single Settings form.
struct PrivacySettingsView: View {
    var body: some View {
        Form {
            Section {
                // No telemetry of any kind ships in the app — no crash reporter,
                // no analytics SDK. State that plainly instead of showing toggles
                // that imply collection is happening (App Store privacy-label
                // truthfulness; the old dead toggles were a rejection risk).
                Label("Earshot collects no data", systemImage: "hand.raised")

                // Hosted policy links (#463). Real SwiftUI `Link`s so the system
                // opens Safari; hints make clear they leave the app.
                if let url = PrivacyPolicy.policyURL {
                    Link(destination: url) {
                        Label("Read the privacy policy", systemImage: "arrow.up.right.square")
                    }
                    .accessibilityHint("Opens the privacy policy in your browser, outside Earshot")
                }
                if let url = PrivacyPolicy.collectionURL {
                    Link(destination: url) {
                        Label("What does Earshot collect?", systemImage: "arrow.up.right.square")
                    }
                    .accessibilityHint("Opens the data-collection summary in your browser, outside Earshot")
                }
            } footer: {
                // No section header: the "Privacy" navigation title already names
                // the screen, so a matching header would be a redundant VoiceOver
                // heading stop.
                Text("Your subscriptions, queue, folders, bookmarks, playback state, listening history, and shared settings can sync through your private iCloud account. Downloads, purchase access, and device-only settings stay on this device. No crash reporting, analytics, third-party trackers, or advertising IDs.")
            }
        }
        .navigationTitle("Privacy")
    }
}
