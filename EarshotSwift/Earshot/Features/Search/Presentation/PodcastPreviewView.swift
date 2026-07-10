import SwiftUI
import SwiftData

/// A read-only preview of an UN-subscribed directory search result (#499). Reached
/// by the primary Activate / tap on a directory row so a user can read about a show
/// — artwork, title, author, description, and a few recent episodes — and decide
/// before following. The Follow / Unfollow control here mirrors the row's toggle, so
/// the user can act either from the list or from the detail.
///
/// This is deliberately NOT `EpisodeListView`: that view takes a subscribed
/// `Podcast` `@Model` and reads `podcast.episodes` from the store. A directory hit
/// has no stored podcast or episodes, so the preview fetches the feed itself (via
/// ``PodcastPreviewModel``) and shows value-type ``PreviewEpisode``s. Already-
/// subscribed results route to `EpisodeListView` upstream and never land here.
struct PodcastPreviewView: View {
    let result: PodcastSearchResult

    @Environment(\.modelContext) private var context

    /// The shared playback engine, so a preview episode can STREAM directly from
    /// here without subscribing or downloading (#517). Injected the same way the
    /// search flow injects it (see `SearchView`).
    @Environment(PlayerService.self) private var player

    /// The shared downloader, so subscribing from a preview auto-downloads the
    /// newest episodes just like following from search or the Library (#639).
    @Environment(DownloadManager.self) private var downloads

    /// Earshot Plus entitlement, for the free-tier podcast cap gate (#635).
    @Environment(EntitlementStore.self) private var entitlements

    /// Subscriptions, so the Follow / Unfollow control reflects live state and the
    /// label flips the moment the toggle completes — without re-entering the view.
    @Query private var podcasts: [Podcast]

    @State private var model = PodcastPreviewModel()

    /// Presents the Earshot Plus paywall (#632) when following this podcast
    /// would hit the free-tier cap. Set from `toggleFollow()`'s catch block,
    /// in ADDITION to the existing VoiceOver announcement.
    @State private var showPaywall = false

    private var subscribed: Bool {
        podcasts.contains { $0.feedURL == result.feedURL }
    }

    var body: some View {
        List {
            Section { header }

            switch model.state {
            case .loading:
                loadingRow
            case .failed:
                failedRow
            case let .loaded(description, episodes):
                if let description {
                    Section("About") {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(AppColor.primaryText)
                    }
                }
                if !episodes.isEmpty {
                    Section("Recent episodes") {
                        ForEach(episodes) { episode in
                            episodeRow(episode)
                        }
                    }
                }
            }
        }
        .navigationTitle(result.title)
        .navigationBarTitleDisplayMode(.inline)
        // Earshot Plus paywall (#632), dismissible via its own explicit Close
        // button, never drag-only.
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .task { await model.load(feedURL: result.feedURL) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .center, spacing: Spacing.sm) {
            PodcastArtwork(urlString: result.artworkURL, size: 120, cornerRadius: 12)
            Text(result.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let author = result.author, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(AppColor.secondaryText)
                    .multilineTextAlignment(.center)
            }
            followButton
                .padding(.top, Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
    }

    /// The prominent Follow / Unfollow control. A real `Button` so VoiceOver gets
    /// the correct role; the label flips with `subscribed`, and `accessibilityValue`
    /// carries the "Following" state without colour alone signalling it. Large
    /// control size keeps it past the 44pt minimum at every Dynamic Type size.
    private var followButton: some View {
        Button {
            toggleFollow()
        } label: {
            Label(
                FollowToggle.actionLabel(subscribed: subscribed),
                systemImage: subscribed ? "checkmark.circle.fill" : "plus.circle"
            )
            .frame(minHeight: Spacing.minTouchTarget)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .modifier(SubscribedAccessibilityValue(subscribed: subscribed))
        .accessibilityHint(subscribed
            ? "Unfollows this podcast"
            : "Follows this podcast and adds recent episodes to your inbox")
    }

    // MARK: Loaded content rows

    @ViewBuilder
    private func episodeRow(_ episode: PreviewEpisode) -> some View {
        if episode.audioURL.isEmpty {
            // No enclosure URL: render a static, non-playable row so a feed missing
            // audio degrades gracefully rather than offering a dead play action.
            episodeRowContent(episode)
                .accessibilityElement(children: .combine)
        } else {
            // A Button is already a single VoiceOver element with the button trait,
            // so the one-stop-per-row requirement is preserved without combining.
            Button {
                streamPreview(episode)
            } label: {
                episodeRowContent(episode)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Streams this episode")
        }
    }

    private func episodeRowContent(_ episode: PreviewEpisode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(episode.title)
                .font(.body)
                .lineLimit(2)
            if let meta = episodeMeta(episode) {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Visible date + length line for a preview episode. Returns nil when neither
    /// is known so no empty caption (and no dead VoiceOver value) is rendered.
    private func episodeMeta(_ episode: PreviewEpisode) -> String? {
        var parts: [String] = []
        if let date = episode.pubDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if let seconds = episode.durationSeconds, seconds > 0 {
            parts.append(StatsLogic.spokenDuration(seconds))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var loadingRow: some View {
        Section {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text("Loading episodes…")
                    .foregroundStyle(AppColor.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading episodes")
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var failedRow: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Error is signalled by icon + text, never colour alone.
                Label {
                    Text("Couldn't load this podcast. Check your connection.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColor.error)
                }
                .accessibilityElement(children: .combine)
                Button {
                    Task { await model.load(feedURL: result.feedURL) }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityHint("Retry loading this podcast's details")
            }
        }
    }

    // MARK: Actions

    /// Streams a preview episode straight from the player engine WITHOUT
    /// subscribing, downloading, or persisting anything (#517). Falls back to the
    /// show artwork for the Now Playing surfaces when the episode has none, and
    /// passes the show title so the lock screen reads the podcast name.
    private func streamPreview(_ episode: PreviewEpisode) {
        player.playPreview(
            guid: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            showTitle: result.title,
            episodeDescription: episode.episodeDescription,
            artworkURL: episode.artworkURL ?? result.artworkURL,
            chapterURL: episode.chapterURL,
            durationSeconds: episode.durationSeconds
        )
    }

    /// Follow when not subscribed, unfollow when subscribed. The `@Query` updates
    /// reactively, so the button label and value flip on completion without the
    /// user re-entering the view. Subscribe is async (it fetches and seeds the
    /// inbox); unsubscribe is a synchronous local delete.
    private func toggleFollow() {
        if let existing = podcasts.first(where: { $0.feedURL == result.feedURL }) {
            if SubscriptionRepository(context: context).unsubscribe(existing) {
                Announcer.announce(FollowToggle.announcement(nowFollowing: false, title: result.title))
            }
        } else {
            Task {
                do {
                    _ = try await SubscriptionRepository(context: context, downloader: downloads, isEntitled: entitlements.isEntitled).subscribe(feedURL: result.feedURL)
                    Announcer.announce(FollowToggle.announcement(nowFollowing: true, title: result.title))
                } catch {
                    AppLog.networking.error(
                        "Follow from preview failed for \(result.feedURL, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    let detail = (error as? LocalizedError)?.errorDescription
                    Announcer.announce(detail.map { "Couldn't follow \(result.title). \($0)" } ?? "Couldn't follow \(result.title)")
                    // In addition to the announcement above: an 11th-podcast
                    // attempt is exactly the moment a paywall should offer the
                    // upgrade (#632).
                    if case SubscriptionError.podcastCapReached = error {
                        showPaywall = true
                    }
                }
            }
        }
    }
}

/// Applies an `accessibilityValue` of "Following" only when subscribed. Omitting
/// the modifier entirely (rather than passing "") keeps VoiceOver from speaking an
/// empty value as a stray pause on a not-yet-followed control.
private struct SubscribedAccessibilityValue: ViewModifier {
    let subscribed: Bool

    func body(content: Content) -> some View {
        if subscribed {
            content.accessibilityValue("Following")
        } else {
            content
        }
    }
}
