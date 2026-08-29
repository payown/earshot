import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class SettingsStoreTests: XCTestCase {

    func testChangesPersistAndReload() {
        let ctx = TestStore.freshContext()
        let store = SettingsStore()
        store.configure(context: ctx)

        store.globalSpeed = 1.5
        store.wifiOnlyDownloads = false
        store.downloadCompletionNotifications = true
        store.skipForwardSeconds = 45
        store.launchScreen = .queue

        // A fresh store over the same context reads the persisted values.
        let reloaded = SettingsStore()
        reloaded.configure(context: ctx)
        XCTAssertEqual(reloaded.globalSpeed, 1.5)
        XCTAssertFalse(reloaded.wifiOnlyDownloads)
        XCTAssertTrue(reloaded.downloadCompletionNotifications)
        XCTAssertEqual(reloaded.skipForwardSeconds, 45)
        XCTAssertEqual(reloaded.launchScreen, .queue)
    }

    func testDefaultsBeforeConfigure() {
        let store = SettingsStore()
        XCTAssertEqual(store.globalSpeed, SettingsDefault.globalSpeed)
        XCTAssertTrue(store.wifiOnlyDownloads)
        XCTAssertFalse(store.downloadCompletionNotifications)
        XCTAssertEqual(store.transcriptExportMetadata, .speakersOnly)
        XCTAssertTrue(store.hapticFeedbackEnabled)
    }

    func testFreshInstallDefaultsTranscriptExportsToSpeakersOnly() {
        let context = TestStore.freshContext()
        let settings = SettingsStore()

        settings.configure(context: context)

        XCTAssertEqual(settings.transcriptExportMetadata, .speakersOnly)
        XCTAssertEqual(
            AppSettingsStore(context: context).rawValue(SettingsKey.transcriptExportMetadata),
            TranscriptExportMetadata.speakersOnly.rawValue
        )
    }

    func testExistingInstallRetainsSpeakersAndTimestamps() {
        let context = TestStore.freshContext()
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.onboardingComplete)
        let settings = SettingsStore()

        settings.configure(context: context)

        XCTAssertEqual(settings.transcriptExportMetadata, .speakersAndTimestamps)
    }

    func testTranscriptExportMetadataPersistsEveryChoiceAcrossRelaunch() {
        let context = TestStore.freshContext()
        let settings = SettingsStore()
        settings.configure(context: context)

        for metadata in TranscriptExportMetadata.allCases {
            settings.transcriptExportMetadata = metadata
            let reloaded = SettingsStore()
            reloaded.configure(context: context)
            XCTAssertEqual(reloaded.transcriptExportMetadata, metadata)
        }
    }

    func testAccessibilitySpeechDefaultsAndChangesPersist() {
        let ctx = TestStore.freshContext()
        let store = SettingsStore()
        store.configure(context: ctx)
        XCTAssertEqual(store.episodeSpokenDetails, EpisodeSpokenDetails())
        XCTAssertEqual(store.spokenPodcastDescriptionMode, .brief)

        store.spokenEpisodePodcastName = false
        store.spokenEpisodeDuration = false
        store.spokenEpisodeDescriptionMode = .full
        store.spokenPodcastDescriptionMode = .off

        let reloaded = SettingsStore()
        reloaded.configure(context: ctx)
        XCTAssertFalse(reloaded.spokenEpisodePodcastName)
        XCTAssertFalse(reloaded.spokenEpisodeDuration)
        XCTAssertEqual(reloaded.spokenEpisodeDescriptionMode, .full)
        XCTAssertEqual(reloaded.spokenPodcastDescriptionMode, .off)
    }

    func testHapticFeedbackDefaultsOnAndPersistsOff() {
        let context = TestStore.freshContext()
        let settings = SettingsStore()
        settings.configure(context: context)
        XCTAssertTrue(settings.hapticFeedbackEnabled)

        settings.hapticFeedbackEnabled = false

        let reloaded = SettingsStore()
        reloaded.configure(context: context)
        XCTAssertFalse(reloaded.hapticFeedbackEnabled)
        XCTAssertTrue(AppSettingScope.isLocal(SettingsKey.hapticFeedbackEnabled))
    }

    /// Season/episode numbering is OFF by default and round-trips like any other
    /// boolean preference (#452). Default-off means rows show/speak no numbering
    /// until the user opts in.
    func testShowEpisodeNumbersDefaultsFalseAndPersists() {
        XCTAssertFalse(SettingsDefault.showEpisodeNumbers)

        let ctx = TestStore.freshContext()
        let store = SettingsStore()
        store.configure(context: ctx)
        XCTAssertFalse(store.showEpisodeNumbers, "Numbering must be off by default")

        store.showEpisodeNumbers = true

        let reloaded = SettingsStore()
        reloaded.configure(context: ctx)
        XCTAssertTrue(reloaded.showEpisodeNumbers, "The opt-in must persist")
    }

    /// Auto-advance settings default true (existing unconditional behavior) and
    /// round-trip through the store like any other boolean preference (#446).
    func testAutoAdvanceDefaultsTrueAndPersist() {
        let ctx = TestStore.freshContext()
        let store = SettingsStore()
        store.configure(context: ctx)
        XCTAssertTrue(store.continueAfterEpisode)
        XCTAssertTrue(store.continueAfterGroupEnds)

        store.continueAfterEpisode = false
        store.continueAfterGroupEnds = false

        let reloaded = SettingsStore()
        reloaded.configure(context: ctx)
        XCTAssertFalse(reloaded.continueAfterEpisode)
        XCTAssertFalse(reloaded.continueAfterGroupEnds)
    }

    func testFactoryResetDeletesEverything() {
        let ctx = TestStore.freshContext()
        let p = Podcast(feedURL: "https://x/a.xml", title: "Show")
        ctx.insert(p)
        ctx.insert(Episode(guid: "g", title: "Ep", audioURL: "https://x/a.mp3"))
        try? ctx.save()

        SettingsReset.deleteAllLocalData(context: ctx)

        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Episode>()), 0)
    }

    func testOPMLExportRoundTripsFeedURLs() {
        let opml = OPMLDocument.export([
            (title: "A & B", feedURL: "https://a.com/feed"),
            (title: "C", feedURL: "https://c.com/feed"),
        ])
        XCTAssertEqual(OPMLDocument.feedURLs(from: opml), ["https://a.com/feed", "https://c.com/feed"])
    }

    func testOPMLImportDeduplicatesAndIgnoresJunk() {
        let opml = """
        <opml><body>
        <outline xmlUrl="https://a.com/feed"/>
        <outline xmlUrl="https://a.com/feed"/>
        <outline text="no url"/>
        </body></opml>
        """
        XCTAssertEqual(OPMLDocument.feedURLs(from: opml), ["https://a.com/feed"])
    }
}
