import SwiftUI

/// The three ways to add a new podcast, as a reusable vertical button group:
/// search the directory, add by RSS URL, and import an OPML file. Shared by the
/// onboarding "Add your first podcast" page and the Library tab's Add Podcast
/// sheet so the two can never drift apart.
///
/// This view owns only the buttons; the caller supplies what each one does. That
/// keeps presentation-versus-navigation cleanly split: onboarding drives sheets and
/// a `.fileImporter` it already hosts, while ``AddPodcastView`` drives its own. Each
/// button is a single, clearly-labelled VoiceOver node (a `Label` inside a system
/// `Button`), and the visual hierarchy (filled primary, then two bordered) matches
/// the onboarding order so muscle memory carries over.
struct AddPodcastOptions: View {
    let onSearch: () -> Void
    let onAddByURL: () -> Void
    let onImportOPML: () -> Void

    var body: some View {
        VStack(spacing: Spacing.md) {
            Button(action: onSearch) {
                Label("Search podcasts", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Find new podcasts in the directory")

            Button(action: onAddByURL) {
                Label("Add by RSS URL", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Paste a podcast feed address")

            Button(action: onImportOPML) {
                Label("Import OPML file", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Add many podcasts from an OPML file")
        }
    }
}
