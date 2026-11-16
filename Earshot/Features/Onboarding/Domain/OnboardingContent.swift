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

/// The ten onboarding pages, the same for everyone. The add-podcast and final
/// Start Listening gates remain in their existing positions relative to each
/// other, while the pages explain the current app's most useful controls.
enum OnboardingContent {
    static let pages: [OnboardingPage] = [
        OnboardingPage(
            id: 0, symbol: "ear",
            title: "Welcome to Earshot",
            body: "A podcast player built for the way you listen.\n\nFollow your favorite shows, choose what to hear next, and make the controls work for you. This short guide introduces the main features and where to find them."
        ),
        OnboardingPage(
            id: 1, symbol: "tray.and.arrow.down",
            title: "Inbox, Queue, and Downloads",
            body: "Your Inbox helps you find new episodes. Your Queue holds episodes you've chosen to listen to. Downloads are audio files stored on this device for offline listening.\n\nThese serve different purposes. Removing an episode from the Queue is not the same as removing its download.\n\nIn a podcast's settings, you can choose whether new episodes go to the Inbox or automatically enter your Queue."
        ),
        OnboardingPage(
            id: 2, symbol: "line.3.horizontal.decrease.circle",
            title: "Find the episodes you want",
            body: "Open Library, choose a podcast, and use Filter episodes to show Unplayed, Partially Played, or All episodes. Use Search episodes to narrow the list.\n\nFor rules that apply to future episodes, open Podcast settings, then Episode Filters. Test your rules against recent episodes before saving them. Episodes excluded by those rules remain available in your Library."
        ),
        OnboardingPage(
            id: 3, symbol: "bolt.circle",
            title: "Make actions yours",
            body: "Open Settings, then Quick Actions, to choose and reorder actions for episodes, podcasts, and the Queue.\n\nWith VoiceOver, use the Actions rotor to access enabled actions in the order you choose. On a podcast's episode list and in Queue, double tap opens details.\n\nThe Download / Remove Download setting covers both jobs. An episode's action offers Download when needed and Remove download when its audio is already downloaded."
        ),
        OnboardingPage(
            id: 4, symbol: "text.badge.plus",
            title: "Choose your listening order",
            body: "Add episodes to the Queue when you want to hear them next. Open Queue, then Edit, to reorder them. With VoiceOver, use the Move actions.\n\nTo add future episodes automatically, open Library, choose a podcast, open Podcast settings, and turn on Add new episodes to queue. That screen also lets you choose when episodes expire from the Queue or Inbox."
        ),
        OnboardingPage(
            id: 5, symbol: "folder",
            title: "Organize with folders",
            body: "Open Library, then Folders, to organize your listening.\n\nTo organize a whole podcast, open its Podcast settings and choose Manage folders. A podcast can belong to more than one folder.\n\nEpisode actions let you Add to another folder without removing existing memberships, or Move to one folder to keep the episode only in the folder you choose."
        ),
        OnboardingPage(
            id: 6, symbol: "square.and.arrow.up",
            title: "Download and export audio",
            body: "Download episodes to listen offline. Open Settings, then Downloads, to manage download preferences, including Wi-Fi requirements.\n\nUse an episode's Export audio action to share its audio file with another app or save it elsewhere. Earshot needs a local audio file for this and may need to download it first. Export audio shares the audio itself, not an episode link or transcript."
        ),
        OnboardingPage(
            id: 7, symbol: "lock.shield",
            title: "Your privacy and iCloud",
            body: "Your subscriptions, queue, folders, bookmarks, playback state, listening history, and shared settings can sync through your private iCloud account.\n\nDownloads and device-only settings stay on this device. Open Settings, then iCloud Sync, to check sync status.\n\nEarshot does not include its own analytics, advertising trackers, or crash-reporting service."
        ),
        OnboardingPage(
            id: 8, symbol: "plus.circle",
            title: "Add your first podcast",
            body: "Find a show by searching, add its RSS feed address, or import your subscriptions from an OPML file. Choose the method that works for you.",
            isAddPodcast: true
        ),
        OnboardingPage(
            id: 9, symbol: "checkmark.circle",
            title: "Ready to listen",
            body: "Start with your Inbox, open a podcast in Library, or build your Queue.\n\nFor more help, open Settings, then Help & About, then Inbox, Queue, and Downloads guide. You can return to Settings whenever you want to change how Earshot works for you."
        ),
    ]
}
