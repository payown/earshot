import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The seven-screen onboarding flow, shown once on first launch. Same for
/// everyone (PRD 6). The "Add your first podcast" page hosts Search/Add, and the
/// final "Start Listening" is gated on having at least one subscription.
struct OnboardingView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var podcasts: [Podcast]

    @State private var pageIndex = 0
    @State private var showingAdd = false
    @State private var showingSearch = false
    @State private var importingOPML = false
    @AccessibilityFocusState private var focusedPage: Int?

    private let pages = OnboardingContent.pages
    private var isLastPage: Bool { pageIndex == pages.count - 1 }
    private var hasPodcast: Bool { !podcasts.isEmpty }

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
            NavigationStack { SearchView() }
        }
        // Reuses the same shared import pipeline as Settings and the share sheet:
        // read + security-scope + import + announce all live in OPMLFileImporter,
        // so every entry point behaves identically. A successful import inserts
        // podcasts, which @Query observes — hasPodcast flips and "Start Listening"
        // unlocks with no extra wiring.
        .fileImporter(
            isPresented: $importingOPML,
            allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml]
        ) { result in
            handleImport(result)
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
            Button {
                showingSearch = true
            } label: {
                Label("Search podcasts", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                showingAdd = true
            } label: {
                Label("Add by RSS URL", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                importingOPML = true
            } label: {
                Label("Import OPML file", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if hasPodcast {
                Text("^[\(podcasts.count) podcast](inflect: true) added")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                .accessibilityHint(hasPodcast ? "" : "Add a podcast first to continue.")
            } else {
                Button {
                    withAnimation(Motion.preferred(.default)) { pageIndex += 1 }
                    focusedPage = pageIndex
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.lg)
    }

    private func complete() {
        settings.onboardingComplete = true
        Announcer.announce("Onboarding complete. Welcome to Earshot.")
        dismiss()
    }

    /// Routes a picked OPML file through the shared importer. On `.success`, the
    /// importer reads + security-scopes + imports + announces the outcome (so
    /// there's no duplicate announcement here). On `.failure`, log and stay put —
    /// a picker error must never crash onboarding.
    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            Task {
                await OPMLFileImporter.importFile(at: url, context: context)
            }
        case let .failure(error):
            AppLog.data.error("Onboarding OPML import picker failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
