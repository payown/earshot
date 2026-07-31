import SwiftUI

/// Settings → About (PRD 17, issue #410).
///
/// Static informational screen: who makes Earshot, the BITS / ACB
/// acknowledgement, thanks to beta testers, the open-source notice with a link
/// to the public repo, and the running app version + build number.
///
/// All text uses semantic fonts and `Theme`/system colors so it follows the
/// user's Dynamic Type and appearance settings. The repo Link is a real
/// SwiftUI `Link`, so the system handles opening Safari and VoiceOver hints make
/// clear it leaves the app.
@MainActor
struct AboutView: View {
    /// Verbatim per PRD 17 — do not paraphrase.
    private static let acknowledgement =
        "Built with thanks to the communities that shaped it: BITS (Blind Information Technology Solutions), an affiliate of the American Council of the Blind, and the broader ACB community."

    private static let repoURL = URL(string: "https://github.com/payown/earshot")

    var body: some View {
        Form {
            Section {
                Text("Earshot is a Payown Media LLC project.")
                    .font(.body)
            }

            Section {
                Text(Self.acknowledgement)
                    .font(.body)
            } header: {
                sectionHeader("Acknowledgements")
            }

            Section {
                Text("Thank you to my wife, for her patience and support while I built this.")
                    .font(.body)
                Text("And thank you to every beta tester who helped make Earshot real.")
                    .font(.body)
            } header: {
                sectionHeader("Thanks")
            }

            Section {
                Text("Open source. MIT licensed.")
                    .font(.body)

                if let url = Self.repoURL {
                    Link(destination: url) {
                        Label("View source on GitHub", systemImage: "arrow.up.right.square")
                    }
                    .accessibilityHint("Opens github dot com in your browser, outside Earshot")
                }
            } header: {
                sectionHeader("Source")
            }

            Section {
                LabeledContent("Version", value: AppInfo.version)
                    .accessibilityElement(children: .combine)
                LabeledContent("Build", value: AppInfo.build)
                    .accessibilityElement(children: .combine)
            } header: {
                sectionHeader("App")
            }

            // Visual room is intentionally left at the bottom for the v1.1
            // "Support Earshot" link (out of scope for this issue, #410).
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A section header carrying the `.isHeader` trait with an explicit label so
    /// VoiceOver announces a single header node (no duplicate text node).
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .accessibilityAddTraits(.isHeader)
    }
}
