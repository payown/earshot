import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The seven-screen onboarding flow, shown once on first launch. Same for
/// everyone (PRD 6). The "Add your first podcast" page hosts Search/Add/Import,
/// and the final "Start Listening" is gated on having at least one subscription.
struct OnboardingView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(OPMLImportProgress.self) private var importProgress
    @Environment(\.dismiss) private var dismiss
    @Query private var podcasts: [Podcast]

    @State private var pageIndex = 0
    @State private var showingAdd = false
    @State private var showingSearch = false
    @State private var importingOPML = false
    @AccessibilityFocusState private var focusedPage: Int?

    private let pages = OnboardingContent.pages
    private var isLastPage: Bool { pageIndex == pages.count - 1 }
    private var hasPodcast: Bool { !podcasts.isEmpty }
    /// The page currently shown. `pageIndex` is the page's `id`, which equals its
    /// array index here, but look it up by `id` so the gate stays correct even if
    /// pages are ever reordered.
    private var currentPage: OnboardingPage? { pages.first { $0.id == pageIndex } }

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $pageIndex) {
                ForEach(pages) { page in
                    pageView(page)
                        .tag(page.id)
                        // Paged TabView keeps every page mounted; hide the
                        // offscreen ones so VoiceOver can't swipe into all seven
                        // as one flattened list. Back/Next is the accessible path.
                        .accessibilityHidden(page.id != pageIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            controls
        }
        .sheet(isPresented: $showingAdd) { AddFeedView() }
        .sheet(isPresented: $showingSearch) {
            NavigationStack { SearchView(scope: .addPodcast) }
        }
        .fileImporter(
            isPresented: $importingOPML,
            allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml]
        ) { result in
            handleImport(result)
        }
    }

    /// Imports a user-picked OPML file via the shared importer. Read +
    /// security-scope + import + the "Imported N podcasts" announcement all live in
    /// ``OPMLFileImporter`` so onboarding behaves identically to Settings and the
    /// share-sheet path. Passing the shared `importProgress` drives the app-wide
    /// import-progress screen (presented from `RootView`), so it appears over
    /// onboarding automatically — we don't present it here. A successful import
    /// populates `podcasts`, which unlocks "Start Listening" on the final page.
    private func handleImport(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else {
            if case let .failure(error) = result {
                AppLog.data.error("Onboarding OPML import: picker failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        Task {
            await OPMLFileImporter.importFile(at: url, context: context, progress: importProgress)
        }
    }

    private var header: some View {
        HStack {
            Text("Page \(pageIndex + 1) of \(pages.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if !isLastPage {
                Button("Skip") { complete() }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
    }

    private func pageView(_ page: OnboardingPage) -> some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                Image(systemName: page.symbol)
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .padding(.top, Spacing.xxl)
                    .accessibilityHidden(true)

                Text(page.title)
                    .font(.title)
                    .bold()
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    // Position is spoken with the title when focus lands here.
                    .accessibilityLabel("\(page.title), page \(page.id + 1) of \(pages.count)")
                    .accessibilityFocused($focusedPage, equals: page.id)

                Text(page.body)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if page.isAddPodcast {
                    addPodcastButtons
                }
            }
            .padding(.horizontal, Spacing.xl)
            .frame(maxWidth: .infinity)
        }
    }

    private var addPodcastButtons: some View {
        VStack(spacing: Spacing.md) {
            // Shared with the Library tab's Add Podcast sheet so the two can't drift.
            AddPodcastOptions(
                onSearch: { showingSearch = true },
                onAddByURL: { showingAdd = true },
                onImportOPML: { importingOPML = true }
            )

            if hasPodcast {
                Text("^[\(podcasts.count) podcast](inflect: true) added")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // Explains why Next is disabled and points to the way out (Skip),
                // so the gate never reads as a dead end. Plain text, read in
                // logical order right after the add actions.
                Text("Add a podcast above, or tap Skip to continue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, Spacing.md)
    }

    private var controls: some View {
        HStack(spacing: Spacing.md) {
            if pageIndex > 0 {
                Button {
                    withAnimation(Motion.preferred(.default)) { pageIndex -= 1 }
                    focusedPage = pageIndex
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
            Spacer()
            if isLastPage {
                Button(action: complete) {
                    Text("Start Listening")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasPodcast)
                // Only attach a hint when the button is disabled. Passing "" can be
                // spoken as a pause (dead air) by VoiceOver, so we omit the modifier
                // entirely when there's nothing to say. When enabled, the
                // "Start Listening" label is self-explanatory and needs no hint.
                .modifier(DisabledHint(isDisabled: !hasPodcast,
                                       hint: "Add a podcast first to continue."))
            } else {
                let nextEnabled = currentPage?.isNextEnabled(hasPodcast: hasPodcast) ?? true
                Button {
                    withAnimation(Motion.preferred(.default)) { pageIndex += 1 }
                    focusedPage = pageIndex
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!nextEnabled)
                // Disabled-only hint; avoid passing "" (potential VoiceOver dead air).
                .modifier(DisabledHint(isDisabled: !nextEnabled,
                                       hint: "Add a podcast above first, or use Skip to continue."))
            }
        }
        .padding(Spacing.lg)
    }

    private func complete() {
        settings.onboardingComplete = true
        Announcer.announce("Onboarding complete. Welcome to Earshot.")
        dismiss()
    }
}

/// Attaches an `accessibilityHint` only while the control is disabled. Applying
/// the modifier conditionally (rather than passing "" when there's nothing to
/// say) avoids VoiceOver speaking an empty hint as a pause. A disabled button is
/// announced as "dimmed" by VoiceOver, and this hint then explains how to enable
/// it.
private struct DisabledHint: ViewModifier {
    let isDisabled: Bool
    let hint: String

    func body(content: Content) -> some View {
        if isDisabled {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}
