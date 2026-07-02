import Foundation

/// One onboarding page. `addPodcast` marks the page that hosts the add-a-podcast
/// actions and gates "Start Listening".
struct OnboardingPage: Identifiable, Equatable {
    let id: Int
    let symbol: String
    let title: String
    let body: String
    var isAddPodcast: Bool = false
}

extension OnboardingPage {
    /// Whether the "Next" button should be enabled on this page.
    ///
    /// Every page enables Next except the add-podcast page, which is gated until
    /// the user has added at least one podcast (search-subscribe, RSS add, or OPML
    /// import). "Skip" stays available on every page regardless, so a user who
    /// doesn't want to add a podcast yet is never trapped. Pure and side-effect
    /// free so it can be unit-tested without instantiating the view.
    func isNextEnabled(hasPodcast: Bool) -> Bool {
        guard isAddPodcast else { return true }
        return hasPodcast
    }
}

/// The seven onboarding pages, the same for everyone (PRD 6). Mirrors the
/// Flutter onboarding copy.
enum OnboardingContent {
    static let pages: [OnboardingPage] = [
        OnboardingPage(
            id: 0, symbol: "ear",
            title: "Welcome to Earshot",
            body: "A podcast player built for the way you listen."
        ),
        OnboardingPage(
            id: 1, symbol: "tray.and.arrow.down",
            title: "How your content flows",
            body: "Follow a podcast and new episodes arrive in your Inbox. Triage them into your Queue when you're ready to listen. Mark a podcast as Auto-Queue and new episodes skip the Inbox entirely."
        ),
        OnboardingPage(
            id: 2, symbol: "lock.shield",
            title: "Your privacy",
            body: "Earshot collects no data. Your subscriptions, listening history, and settings stay on this device. No crash reporting, no analytics, no third-party trackers, no advertising IDs."
        ),
        OnboardingPage(
            id: 3, symbol: "bolt.circle",
            title: "Quick Actions",
            body: "Every episode and podcast has Quick Actions — shortcuts you arrange yourself. With VoiceOver they appear in the Actions rotor in the order you choose."
        ),
        OnboardingPage(
            id: 4, symbol: "clock.arrow.circlepath",
            title: "Queue expiration",
            body: "Tired of stale news episodes piling up? Set a freshness limit per podcast or folder, and older queued episodes move aside automatically."
        ),
        OnboardingPage(
            id: 5, symbol: "plus.circle",
            title: "Add your first podcast",
            body: "Search for a podcast, paste an RSS URL, or import an OPML file to get started.",
            isAddPodcast: true
        ),
        OnboardingPage(
            id: 6, symbol: "checkmark.circle",
            title: "You're all set",
            body: "You can revisit any of these settings any time from the Settings screen. Happy listening."
        ),
    ]
}
