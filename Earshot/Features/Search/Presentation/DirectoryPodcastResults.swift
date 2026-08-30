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
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @Query private var podcasts: [Podcast]
    @Query private var folders: [PodcastFolder]

    @State private var navigation: DirectoryPodcastNavigation?
    @State private var subscribeFolderPick: FolderPickRequest?
    @State private var showPaywall = false
    @State private var remoteDescriptions: [String: String] = [:]
    @State private var fullDescription: PodcastDescriptionPresentation?

    private var spokenDescriptionMode: SpokenDescriptionMode {
        settings.spokenPodcastDescriptionMode
    }

    private var descriptionLoadKey: String {
        let feeds = results.map { FeedURLIdentity.canonical($0.feedURL) }.joined(separator: "\u{1}")
        return "\(voiceOverEnabled)|\(spokenDescriptionMode.rawValue)|\(feeds)"
    }

    var body: some View {
        ForEach(Array(results.enumerated()), id: \.offset) { _, result in
            DirectoryPodcastRow(
                result: result,
                subscribed: isSubscribed(result),
                description: spokenDescription(for: result),
                descriptionMode: spokenDescriptionMode,
                open: { openDetail(result) },
                toggleFollow: { toggleFollow(result) },
                readFullDescription: {
                    fullDescription = PodcastDescriptionPresentation(
                        title: result.title,
                        descriptionHTML: spokenDescription(for: result)
                    )
                }
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
        .sheet(item: $fullDescription) { PodcastDescriptionView(presentation: $0) }
        .folderPicker($subscribeFolderPick)
        .task(id: descriptionLoadKey) {
            guard DirectoryPodcastDescriptionPolicy.shouldLoad(
                voiceOverEnabled: voiceOverEnabled,
                mode: spokenDescriptionMode
            ) else {
                remoteDescriptions = [:]
                return
            }
            let feedURLs = results.map(\.feedURL)
            let prioritized = await DirectoryPodcastDescriptionService.shared.descriptions(
                for: Array(feedURLs.prefix(4))
            )
            guard !Task.isCancelled else { return }
            remoteDescriptions = prioritized

            let loaded = await DirectoryPodcastDescriptionService.shared.descriptions(
                for: feedURLs
            )
            guard !Task.isCancelled else { return }
            remoteDescriptions = loaded
        }
    }

    private func isSubscribed(_ result: PodcastSearchResult) -> Bool {
        podcasts.contains { FeedURLIdentity.matches($0.feedURL, result.feedURL) }
    }

    private func spokenDescription(for result: PodcastSearchResult) -> String? {
        if let podcast = podcasts.first(where: {
            FeedURLIdentity.matches($0.feedURL, result.feedURL)
        }) {
            return podcast.podcastDescription
        }
        return remoteDescriptions[FeedURLIdentity.canonical(result.feedURL)]
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
    let subscribed: Bool
    let description: String?
    let descriptionMode: SpokenDescriptionMode
    let open: () -> Void
    let toggleFollow: () -> Void
    let readFullDescription: () -> Void

    private var toggleLabel: String {
        FollowToggle.actionLabel(subscribed: subscribed)
    }

    private var rotorActions: [QuickActionItem] {
        var actions = [QuickActionItem(label: toggleLabel, isDestructive: false) {
            toggleFollow()
        }]
        if let description,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            actions.append(QuickActionItem(label: "Read full description", isDestructive: false) {
                readFullDescription()
            })
        }
        return actions
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
        .modifier(OptionalSpokenValue(value:
            DirectoryPodcastRowSpeech.value(
                subscribed: subscribed,
                feedURL: result.feedURL,
                description: description,
                mode: descriptionMode
            )
        ))
        .accessibilityAction { open() }
        // Fixed actions still use Earshot's shared rotor-order compensation;
        // declaring raw accessibility actions here would speak them backwards
        // on the iOS releases covered by QuickActionsRotor.
        .rotorActions(rotorActions)
    }
}

private enum DirectoryPodcastNavigation: Hashable {
    case preview(PodcastSearchResult)
    case subscribed(Podcast)
}
