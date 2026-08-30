import SwiftData
import SwiftUI

/// The shared directory-result renderer used by both typed search and Apple
/// category charts. Keeping navigation and Follow / Unfollow behavior here means
/// category browsing cannot become a reduced copy of the search experience.
struct DirectoryPodcastResults: View {
    let results: [PodcastSearchResult]

    @Environment(\.modelContext) private var context
    @Environment(DownloadManager.self) private var downloads
    @Environment(EntitlementStore.self) private var entitlements

    @Query private var podcasts: [Podcast]
    @Query private var folders: [PodcastFolder]

    @State private var navigation: DirectoryPodcastNavigation?
    @State private var subscribeFolderPick: FolderPickRequest?
    @State private var showPaywall = false

    var body: some View {
        ForEach(Array(results.enumerated()), id: \.offset) { offset, result in
            DirectoryPodcastRow(
                result: result,
                index: offset,
                total: results.count,
                subscribed: isSubscribed(result),
                open: { openDetail(result) },
                toggleFollow: { toggleFollow(result) }
            )
        }
        .navigationDestination(item: $navigation) { destination in
            switch destination {
            case let .preview(result):
                PodcastPreviewView(result: result)
            case let .subscribed(podcast):
                EpisodeListView(podcast: podcast)
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .folderPicker($subscribeFolderPick)
    }

    private func isSubscribed(_ result: PodcastSearchResult) -> Bool {
        podcasts.contains { FeedURLIdentity.matches($0.feedURL, result.feedURL) }
    }

    private func openDetail(_ result: PodcastSearchResult) {
        if let existing = podcasts.first(where: {
            FeedURLIdentity.matches($0.feedURL, result.feedURL)
        }) {
            navigation = .subscribed(existing)
        } else {
            navigation = .preview(result)
        }
    }

    private func toggleFollow(_ result: PodcastSearchResult) {
        if let existing = podcasts.first(where: {
            FeedURLIdentity.matches($0.feedURL, result.feedURL)
        }) {
            if SubscriptionRepository(context: context).unsubscribe(existing) {
                Announcer.announce(FollowToggle.announcement(nowFollowing: false, title: result.title))
            }
        } else {
            subscribe(result)
        }
    }

    private func subscribe(_ result: PodcastSearchResult) {
        Task {
            do {
                let podcast = try await SubscriptionRepository(
                    context: context,
                    downloader: downloads,
                    isEntitled: entitlements.isEntitled
                ).subscribe(feedURL: result.feedURL)
                Announcer.announce(FollowToggle.announcement(nowFollowing: true, title: result.title))
                if FolderLogic.shouldOfferSubscribeToFolder(existingFolderCount: folders.count) {
                    try? await Task.sleep(for: .milliseconds(600))
                    subscribeFolderPick = .podcast(podcast, mode: .add)
                }
            } catch {
                AppLog.networking.error(
                    "Subscribe from directory failed for \(result.feedURL, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                Announcer.announce(
                    "Couldn't follow \(result.title). \(SubscribeErrorMessage.userFacing(error))"
                )
                if case SubscriptionError.podcastCapReached = error {
                    showPaywall = true
                }
            }
        }
    }
}

/// One directory result with the exact two-action interaction used everywhere:
/// Activate opens the show; the named action follows or unfollows it.
private struct DirectoryPodcastRow: View {
    let result: PodcastSearchResult
    let index: Int
    let total: Int
    let subscribed: Bool
    let open: () -> Void
    let toggleFollow: () -> Void

    private var toggleLabel: String {
        FollowToggle.actionLabel(subscribed: subscribed)
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            Button(action: open) {
                HStack(spacing: Spacing.md) {
                    PodcastArtwork(urlString: result.artworkURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).font(.headline).lineLimit(2)
                        if let author = result.author {
                            Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(toggleLabel, action: toggleFollow)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([result.title, result.author].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this podcast")
        .accessibilityValue(
            SearchResultPosition.rowValue(subscribed: subscribed, index: index, total: total)
        )
        .accessibilityAction { open() }
        .accessibilityAction(named: Text(toggleLabel)) { toggleFollow() }
    }
}

private enum DirectoryPodcastNavigation: Hashable {
    case preview(PodcastSearchResult)
    case subscribed(Podcast)
}
