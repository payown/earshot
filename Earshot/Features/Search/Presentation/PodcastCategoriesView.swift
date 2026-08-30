import SwiftUI

/// Apple's podcast taxonomy, presented as native disclosure groups so VoiceOver
/// receives expanded / collapsed state without custom accessibility machinery.
struct PodcastCategoriesView: View {
    var body: some View {
        List {
            Section {
                ForEach(ApplePodcastCategories.all) { category in
                    if category.subcategories.isEmpty {
                        categoryLink(category)
                    } else {
                        DisclosureGroup {
                            categoryLink(category, label: "Top \(category.name) shows")
                            ForEach(category.subcategories) { subcategory in
                                categoryLink(subcategory)
                            }
                        } label: {
                            Text(category.name)
                                .font(.headline)
                        }
                    }
                }
            } footer: {
                Text("Charts are provided by Apple Podcasts for your region.")
            }
        }
        .navigationTitle("Browse categories")
    }

    private func categoryLink(
        _ category: ApplePodcastCategory,
        label: String? = nil
    ) -> some View {
        NavigationLink {
            PodcastCategoryResultsView(category: category)
        } label: {
            Text(label ?? category.name)
        }
        .accessibilityHint("Shows the top podcasts in this category")
    }
}

@MainActor
@Observable
final class PodcastCategoryResultsModel {
    enum State: Equatable {
        case loading
        case loaded([PodcastSearchResult])
        case failed
    }

    private(set) var state: State = .loading
    private let service: any ApplePodcastCategoryFetching
    private let storefront: String

    init(
        service: any ApplePodcastCategoryFetching = ApplePodcastCategoryService(),
        storefront: String = ApplePodcastCategoryService.storefront()
    ) {
        self.service = service
        self.storefront = storefront
    }

    func load(categoryID: String) async {
        state = .loading
        let outcome = await service.topPodcasts(
            categoryID: categoryID,
            storefront: storefront,
            limit: CategoryResultPaging.maximumResults
        )
        guard !Task.isCancelled else { return }
        switch outcome {
        case let .results(results): state = .loaded(results)
        case .failure: state = .failed
        }
    }
}

enum CategoryResultPaging {
    static let pageSize = 25
    static let maximumResults = 100

    static func nextVisibleCount(current: Int, total: Int) -> Int {
        min(max(current, 0) + pageSize, max(total, 0))
    }

    static func loadedAnnouncement(previous: Int, current: Int) -> String {
        let added = max(current - previous, 0)
        return "\(added) more results loaded, \(current) results available"
    }

    static func initialAnnouncement(visible: Int, total: Int, categoryName: String) -> String {
        if visible < total {
            return "\(visible) of \(total) top shows loaded in \(categoryName)"
        }
        let shows = total == 1 ? "show" : "shows"
        return "\(total) top \(shows) loaded in \(categoryName)"
    }
}

struct PodcastCategoryResultsView: View {
    let category: ApplePodcastCategory

    @State private var model = PodcastCategoryResultsModel()
    @State private var visibleCount = CategoryResultPaging.pageSize
    @AccessibilityFocusState private var loadMoreFocused: Bool

    var body: some View {
        List {
            switch model.state {
            case .loading:
                Section {
                    HStack(spacing: Spacing.sm) {
                        ProgressView()
                        Text("Loading podcasts…")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Loading podcasts in \(category.name)")
                    .accessibilityAddTraits(.updatesFrequently)
                }
            case .failed:
                failureSection
            case let .loaded(results):
                loadedContent(results)
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(categoryID: category.id) }
        .onChange(of: model.state) { _, state in
            guard case let .loaded(results) = state, !results.isEmpty else { return }
            let visible = min(CategoryResultPaging.pageSize, results.count)
            Announcer.announce(
                CategoryResultPaging.initialAnnouncement(
                    visible: visible,
                    total: results.count,
                    categoryName: category.name
                )
            )
        }
    }

    private var failureSection: some View {
        Section {
            Label {
                Text("Couldn't load this category. Check your connection.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColor.error)
            }
            .accessibilityElement(children: .combine)

            Button {
                Task { await model.load(categoryID: category.id) }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(minHeight: Spacing.minTouchTarget)
            }
            .accessibilityHint("Retry loading the \(category.name) podcast chart")
        }
    }

    @ViewBuilder
    private func loadedContent(_ results: [PodcastSearchResult]) -> some View {
        if results.isEmpty {
            ContentUnavailableView(
                "No podcasts available",
                systemImage: "waveform",
                description: Text("Apple Podcasts did not return any shows for this category.")
            )
        } else {
            let visible = Array(results.prefix(visibleCount))
            Section("Top shows") {
                DirectoryPodcastResults(results: visible)
                if visible.count < results.count {
                    let nextCount = min(
                        CategoryResultPaging.pageSize,
                        results.count - visible.count
                    )
                    Button {
                        loadMore(total: results.count)
                    } label: {
                        Label("Load \(nextCount) more results", systemImage: "chevron.down")
                            .frame(minHeight: Spacing.minTouchTarget)
                    }
                    .accessibilityHint("Adds the next \(nextCount) podcasts to this list")
                    .accessibilityFocused($loadMoreFocused)
                } else if results.count > CategoryResultPaging.pageSize {
                    Text("All available results loaded")
                        .foregroundStyle(AppColor.secondaryText)
                        .accessibilityFocused($loadMoreFocused)
                }
            }
        }
    }

    private func loadMore(total: Int) {
        let previous = visibleCount
        visibleCount = CategoryResultPaging.nextVisibleCount(current: visibleCount, total: total)
        Announcer.announce(
            CategoryResultPaging.loadedAnnouncement(previous: previous, current: visibleCount)
        )
        loadMoreFocused = true
    }
}
