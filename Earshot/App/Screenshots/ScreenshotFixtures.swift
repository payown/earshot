#if DEBUG
import Foundation
import SwiftData

/// App Store screenshot fixtures (#643). DEBUG-only — never compiled into a
/// Release build.
///
/// PROVENANCE OF THE DATA (read before trusting a capture):
///
/// - Both podcasts and every episode title, GUID, audio URL, artwork URL,
///   author, and publish date below are REAL, pulled from Michael's live
///   Pinecast feeds on 2026-07-11:
///     • Technically Working  — https://pinecast.com/feed/technically-working
///     • Our Perspective      — https://pinecast.com/feed/our-perspective
///   Artwork renders at capture time from the real feed-provided cover URLs
///   (fetched once, then served from `ArtworkCache`), so the shots show the
///   actual show art.
///
/// - Per-episode STATE (played / in-progress position / downloaded / queued /
///   inbox membership) is SET BY THIS FIXTURE to make the screens look
///   lived-in. It does not reflect anyone's real listening history.
///
/// - The ONLY fabricated CONTENT is the chapter list on the featured
///   "Now Playing" episode (Technically Working #170). Its show notes carry
///   timestamped chapter lines whose titles track that episode's real segments
///   (audio-gear talk, the NFB convention trip, Earshot progress). The app's
///   real, shipped show-notes chapter parser (`ChapterParser`) extracts them
///   through the normal path — the chapter FEATURE is real; only this one demo
///   episode's timestamps are authored here. Fabricating a single demo
///   episode's chapters is standard practice for store screenshots.
///
/// Durations are assigned realistic values because the source feeds omit
/// `itunes:duration`.
@MainActor
enum ScreenshotFixtures {

    /// GUID of the episode the "Now Playing" shot loads. Exposed so the harness
    /// can find it after seeding.
    static let nowPlayingEpisodeGUID = "https://pinecast.com/guid/7baa238c-1c81-4225-ae54-189d75ecdd8c"

    /// Feed URL of the show the "episode list" shot pushes into.
    static let featuredPodcastFeedURL = "https://pinecast.com/feed/technically-working"

    // MARK: Seed

    @MainActor
    static func seed(into context: ModelContext) {
        let tw = Podcast(
            feedURL: featuredPodcastFeedURL,
            title: "Technically Working",
            author: "Michael Babcock & Damashe Thomas",
            podcastDescription: "The go-to podcast for tech enthusiasts and productivity seekers. Hosts Michael Babcock and Damashe Thomas talk gear, workflows, accessibility, and building in public.",
            artworkURL: "https://storage.pinecast.net/podcasts/covers/c5286a42-bf78-4390-88e0-c34ff6638d30/TechnicallyWorking_Podcast1400x1400-03.jpg",
            websiteURL: "https://technically-working.pinecast.co",
            language: "en-US",
            autoQueue: true
        )
        let op = Podcast(
            feedURL: "https://pinecast.com/feed/our-perspective",
            title: "Our Perspective",
            author: "Kolby & Michael",
            podcastDescription: "No judgment. That's the only rule. Kolby and Michael are two blind professionals who do a lot of the same things in completely different ways.",
            artworkURL: "https://storage.pinecast.net/podcasts/covers/f17fe106-2376-4407-ae3b-22c1aef022e8/our-perspective-podcast-art-v2.jpg",
            websiteURL: "https://pnc.st/s/our-perspective",
            language: "en-US"
        )
        context.insert(tw)
        context.insert(op)

        // MARK: Technically Working episodes (real titles/GUIDs/audio).

        // #170 — the featured "Now Playing" episode. Downloaded, resumed mid-way,
        // and carrying the demo chapter timestamps in its show notes.
        let e170 = episode(
            guid: nowPlayingEpisodeGUID,
            title: "#170 – Turn the Right Knob, People Hear You",
            audio: "https://pinecast.com/listen/7baa238c-1c81-4225-ae54-189d75ecdd8c.mp3?source=rss&ext=asset.mp3",
            notes: chapteredShowNotes,
            duration: 3005,
            pub: "2026-07-04T06:00:12Z",
            number: 170
        )
        e170.positionSeconds = 1600          // 26:40 — scrubber ~53%
        e170.inboxDismissed = true
        markDownloaded(e170, as: "sc-tw-170.mp3")

        // #169 — in progress, downloaded, still in the inbox (unplayed & new).
        let e169 = episode(
            guid: "https://pinecast.com/guid/9c098f14-de7d-4974-b5ad-8d692288a766",
            title: "#169 – Apple's Price Hikes, Smart Glasses, and AI Policy Whiplash",
            audio: "https://pinecast.com/listen/9c098f14-de7d-4974-b5ad-8d692288a766.mp3?source=rss&ext=asset.mp3",
            notes: "Michael walks through where the Earshot podcast app stands after another round of Claude-assisted work, then the crew digs into Apple's price hikes and the week's AI policy whiplash.",
            duration: 3312,
            pub: "2026-06-29T22:32:00Z",
            number: 169
        )
        e169.positionSeconds = 900           // 15:00 in
        markDownloaded(e169, as: "sc-tw-169.mp3")

        // #168 — played, downloaded, cleared from the inbox.
        let e168 = episode(
            guid: "https://pinecast.com/guid/4e0882d3-2746-463c-8955-4b1d184fb5ee",
            title: "#168 – Multi-Agent Madness: Rebuilding Earshot the Hard Way",
            audio: "https://pinecast.com/listen/4e0882d3-2746-463c-8955-4b1d184fb5ee.mp3?source=rss&ext=asset.mp3",
            notes: "Recorded on Father's Day: Michael and Damashe dig into AI agents, coding workflows, and rebuilding Earshot the hard way.",
            duration: 3600,
            pub: "2026-06-23T02:03:31Z",
            number: 168
        )
        e168.isPlayed = true
        e168.inboxDismissed = true
        markDownloaded(e168, as: "sc-tw-168.mp3")

        // #167 — downloaded, unplayed, in the inbox.
        let e167 = episode(
            guid: "https://pinecast.com/guid/3240cfe1-07d0-4cdc-b340-9d4131f7c84e",
            title: "#167 – We're Going to Atlanta",
            audio: "https://pinecast.com/listen/3240cfe1-07d0-4cdc-b340-9d4131f7c84e.mp3?source=rss&ext=asset.mp3",
            notes: "Mike and Damashe dig into Earshot build 99, react to WWDC 26, and ask whether AI agent devices are actually ready to replace your phone.",
            duration: 2940,
            pub: "2026-06-15T13:07:39Z",
            number: 167
        )
        markDownloaded(e167, as: "sc-tw-167.mp3")

        // #166 — queued (position 0), downloaded.
        let e166 = episode(
            guid: "https://pinecast.com/guid/fc336a5c-8df3-4f92-801c-e618d9dc8d8d",
            title: "#166 – If You Used a Passkey, Why Are You Asking for a Code?",
            audio: "https://pinecast.com/listen/fc336a5c-8df3-4f92-801c-e618d9dc8d8d.mp3?source=rss&ext=asset.mp3",
            notes: "Passkeys are supposed to make life easier, so why is Amazon still asking for a six-digit code? Michael and Damashe dig in.",
            duration: 2760,
            pub: "2026-06-07T01:57:31Z",
            number: 166
        )
        e166.inboxDismissed = true
        markDownloaded(e166, as: "sc-tw-166.mp3")

        // #165 — queued (position 1), not downloaded.
        let e165 = episode(
            guid: "https://pinecast.com/guid/6a089d48-76a4-43f5-b8af-6e63343769a8",
            title: "#165 – No Excuses Left for Inaccessible Apps",
            audio: "https://pinecast.com/listen/6a089d48-76a4-43f5-b8af-6e63343769a8.mp3?source=rss&ext=asset.mp3",
            notes: "Why there are no excuses left for shipping inaccessible apps in 2026.",
            duration: 3180,
            pub: "2026-05-31T13:00:00Z",
            number: 165
        )
        e165.inboxDismissed = true

        for e in [e170, e169, e168, e167, e166, e165] {
            e.podcast = tw
            context.insert(e)
        }

        // MARK: Our Perspective episodes (real titles/GUIDs/audio).

        let op2 = episode(
            guid: "https://pinecast.com/guid/3fea2519-137d-4ef0-8af1-c8f668cdb711",
            title: "No For Right Now",
            audio: "https://pinecast.com/listen/3fea2519-137d-4ef0-8af1-c8f668cdb711.mp3?source=rss&ext=asset.mp3",
            notes: "Michael and Kolby are back after a month off and jump into the feedback they've been getting.",
            duration: 1980,
            pub: "2026-07-07T08:19:00Z",
            number: 2
        )
        // Newest OP episode — stays in the inbox.

        let op1 = episode(
            guid: "https://pinecast.com/guid/5a48a1ab-99f2-45d5-942e-9f7783a3b94b",
            title: "Welcome to Our Perspective",
            audio: "https://pinecast.com/listen/5a48a1ab-99f2-45d5-942e-9f7783a3b94b.mp3?source=rss&ext=asset.mp3",
            notes: "In the first episode, Michael and Kolby introduce the show and dig into two questions about navigating the world as blind professionals.",
            duration: 2460,
            pub: "2026-06-02T09:26:00Z",
            number: 1
        )
        op1.inboxDismissed = true
        markDownloaded(op1, as: "sc-op-1.mp3")   // queued (position 2), downloaded

        let op0 = episode(
            guid: "https://pinecast.com/guid/cec6082f-6c00-4171-8a4d-3ac2147e3f75",
            title: "Trailer: No Judgment — Our Perspective Is Here",
            audio: "https://pinecast.com/listen/cec6082f-6c00-4171-8a4d-3ac2147e3f75.mp3?source=rss&ext=asset.mp3",
            notes: "A first taste of the dynamic — honest, unscripted, and a little unfiltered.",
            duration: 180,
            pub: "2026-04-22T01:15:07Z",
            number: nil
        )
        op0.isPlayed = true
        op0.inboxDismissed = true
        markDownloaded(op0, as: "sc-op-0.mp3")

        for e in [op2, op1, op0] {
            e.podcast = op
            context.insert(e)
        }

        // MARK: Queue (spans both shows so the "grouped" layout is visible).

        enqueue(e166, at: 0, in: context)
        enqueue(e165, at: 1, in: context)
        enqueue(op1, at: 2, in: context)

        // MARK: Settings (so the Settings shot shows a real auto-download value).

        let settings = AppSettingsStore(context: context)
        settings.setBool(true, for: SettingsKey.onboardingComplete)
        settings.setInt(3, for: SettingsKey.autoDownloadCount)        // "3 most recent"
        settings.setBool(true, for: SettingsKey.wifiOnlyDownloads)
        settings.setBool(true, for: SettingsKey.groupQueueEpisodes)   // grouped queue shot
        settings.setLaunchScreen(.inbox)

        try? context.save()
    }

    // MARK: Builders

    private static func episode(
        guid: String,
        title: String,
        audio: String,
        notes: String,
        duration: Int,
        pub: String,
        number: Int?
    ) -> Episode {
        Episode(
            guid: guid,
            title: title,
            audioURL: audio,
            episodeDescription: notes,
            durationSeconds: duration,
            pubDate: date(pub),
            episodeNumber: number
        )
    }

    /// Marks an episode downloaded and drops a placeholder file at its bare
    /// download name so launch reconciliation (`reconcileDownloadPaths`) keeps
    /// the downloaded state instead of resetting it as "file gone" (#575). The
    /// placeholder is empty — no shot renders audio bytes, and the featured
    /// Now Playing episode streams from its real remote URL, so nothing tries to
    /// decode these.
    ///
    /// The one place outside `ActiveDownload.setDownloadStatus(_:on:in:)` that
    /// writes `downloadStatus` directly, and it is exempt on purpose (#701):
    /// `.downloaded` is TERMINAL, so the invariant here is "no `ActiveDownload`
    /// row exists" — and none can, because these episodes are freshly seeded and
    /// have never been downloaded. Nothing to keep in step.
    private static func markDownloaded(_ episode: Episode, as fileName: String) {
        episode.downloadStatus = .downloaded
        episode.downloadPath = fileName
        if let dir = try? DownloadPaths.downloadsDirectory() {
            let url = dir.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
        }
    }

    private static func enqueue(_ episode: Episode, at position: Int, in context: ModelContext) {
        episode.status = .inQueue
        let item = QueueItem(episode: episode, position: position)
        context.insert(item)
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private static func date(_ iso: String) -> Date {
        isoFormatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    /// Show notes for TW #170 with timestamped chapter lines. The prose and
    /// chapter titles track the episode's real segments; the timestamps are
    /// authored here so the shipped `ChapterParser` produces a chapter list for
    /// the "Now Playing" shot. This is the only fabricated content in the seed.
    private static let chapteredShowNotes = """
    <p>Damashe kicks things off with a tale of audio gear gone sideways right before a big trip, and we get into how to actually be heard on a call.</p>
    <p>0:00 Cold open and hellos</p>
    <p>3:20 Audio gear talk: the interface mishap</p>
    <p>12:45 Shipping the demo kit to Austin for NFB</p>
    <p>21:10 Getting your levels right so people hear you</p>
    <p>32:40 Earshot progress and what shipped this week</p>
    <p>44:15 Picks and where to find us</p>
    """
}
#endif
