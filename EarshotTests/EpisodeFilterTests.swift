import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class EpisodeFilterTests: XCTestCase {
    func testWildcardIsCaseInsensitiveByDefaultAndSupportsQuestionMark() {
        let rule = EpisodeFilterRule(
            name: "Date segment", titlePattern: "*d?te*"
        )

        XCTAssertTrue(rule.matches(title: "FIRST DATE UPDATE", durationSeconds: nil))
        XCTAssertFalse(rule.matches(title: "Full show", durationSeconds: nil))
    }

    func testWildcardTreatsRegularExpressionMetacharactersLiterally() {
        let rule = EpisodeFilterRule(
            name: "Literal punctuation", titlePattern: "Show (Part 1) + *"
        )

        XCTAssertTrue(
            rule.matches(title: "Show (Part 1) + Update", durationSeconds: nil)
        )
        XCTAssertFalse(
            rule.matches(title: "Show Part 1 Update", durationSeconds: nil)
        )
    }

    func testRegularExpressionCanOptIntoCaseSensitivity() {
        var rule = EpisodeFilterRule(
            name: "Headlines", titlePattern: "^News [0-9]+$",
            patternKind: .regularExpression
        )
        XCTAssertTrue(rule.matches(title: "news 12", durationSeconds: nil))

        rule.isCaseSensitive = true
        XCTAssertFalse(rule.matches(title: "news 12", durationSeconds: nil))
        XCTAssertTrue(rule.matches(title: "News 12", durationSeconds: nil))
    }

    func testInvalidRegularExpressionCannotMatchOrSave() {
        let rule = EpisodeFilterRule(
            name: "Broken", titlePattern: "[", patternKind: .regularExpression
        )
        let configuration = EpisodeFilterConfiguration(
            isEnabled: true, mode: .keepMatching, rules: [rule]
        )

        XCTAssertNotNil(rule.validationMessage())
        XCTAssertFalse(rule.matches(title: "Anything", durationSeconds: nil))
        XCTAssertNotNil(configuration.validationMessage())
    }

    func testDurationCriterionDoesNotMatchWhenFeedOmitsDuration() {
        let rule = EpisodeFilterRule(
            name: "Full show", minimumDurationMinutes: 45
        )

        XCTAssertFalse(rule.matches(title: "Full show", durationSeconds: nil))
        XCTAssertFalse(rule.matches(title: "Full show", durationSeconds: 44 * 60))
        XCTAssertTrue(rule.matches(title: "Full show", durationSeconds: 45 * 60))
    }

    func testRuleWithTitleAndDurationRequiresBothCriteria() {
        let rule = EpisodeFilterRule(
            name: "Long full show",
            titlePattern: "*full show*",
            minimumDurationMinutes: 45
        )

        XCTAssertTrue(rule.matches(title: "The Full Show", durationSeconds: 46 * 60))
        XCTAssertFalse(rule.matches(title: "The Full Show", durationSeconds: 30 * 60))
        XCTAssertFalse(rule.matches(title: "Long segment", durationSeconds: 60 * 60))
    }

    func testMultipleRulesUseOrWhileModeControlsKeepDecision() {
        let rules = [
            EpisodeFilterRule(name: "Date", titlePattern: "*date*"),
            EpisodeFilterRule(name: "Long", minimumDurationMinutes: 45),
        ]
        let keep = EpisodeFilterConfiguration(
            isEnabled: true, mode: .keepMatching, rules: rules
        )
        let filter = EpisodeFilterConfiguration(
            isEnabled: true, mode: .filterMatching, rules: rules
        )

        XCTAssertTrue(keep.shouldKeep(title: "Date update", durationSeconds: 10 * 60))
        XCTAssertTrue(keep.shouldKeep(title: "Full show", durationSeconds: 60 * 60))
        XCTAssertFalse(keep.shouldKeep(title: "Short news", durationSeconds: 10 * 60))
        XCTAssertFalse(filter.shouldKeep(title: "Date update", durationSeconds: 10 * 60))
        XCTAssertTrue(filter.shouldKeep(title: "Short news", durationSeconds: 10 * 60))
    }

    func testPreviewEvaluatesDraftWhileTopLevelFilteringIsOff() {
        let configuration = EpisodeFilterConfiguration(
            isEnabled: false,
            mode: .filterMatching,
            rules: [EpisodeFilterRule(name: "Long", minimumDurationMinutes: 20)]
        )

        XCTAssertTrue(configuration.shouldKeep(title: "Short segment", durationSeconds: 10 * 60))
        XCTAssertFalse(configuration.shouldKeepForPreview(
            title: "Long show", durationSeconds: 30 * 60
        ))
        XCTAssertTrue(configuration.shouldKeepForPreview(
            title: "Short segment", durationSeconds: 10 * 60
        ))
    }

    func testDisabledRulesDoNotParticipateInMatching() {
        let configuration = EpisodeFilterConfiguration(
            isEnabled: true,
            mode: .keepMatching,
            rules: [
                EpisodeFilterRule(name: "Disabled", isEnabled: false, titlePattern: "*"),
                EpisodeFilterRule(name: "Full", titlePattern: "*full*"),
            ]
        )

        XCTAssertTrue(configuration.shouldKeep(title: "Full show", durationSeconds: nil))
        XCTAssertFalse(configuration.shouldKeep(title: "Segment", durationSeconds: nil))
    }

    func testKeepMatchingWithZeroEnabledRulesCannotSave() {
        let configuration = EpisodeFilterConfiguration(
            isEnabled: true, mode: .keepMatching,
            rules: [EpisodeFilterRule(name: "Disabled", isEnabled: false, titlePattern: "*")]
        )

        XCTAssertFalse(configuration.isActiveAtIngest)
        XCTAssertNotNil(configuration.validationMessage())
    }

    func testKeepMatchingWithZeroEnabledRulesBypassesIngest() {
        let configuration = EpisodeFilterConfiguration(
            isEnabled: true, mode: .keepMatching,
            rules: [EpisodeFilterRule(name: "Disabled", isEnabled: false, titlePattern: "*")]
        )

        XCTAssertTrue(configuration.shouldKeep(title: "Anything", durationSeconds: nil))
    }

    func testDeletingLastKeepRuleWhileFilteringOnCannotSaveAndBypassesIngest() {
        var configuration = EpisodeFilterConfiguration(
            isEnabled: true,
            mode: .keepMatching,
            rules: [EpisodeFilterRule(name: "Only rule", titlePattern: "*show*")]
        )

        configuration.rules.removeAll()
        XCTAssertNotNil(configuration.validationMessage())
        XCTAssertFalse(configuration.isActiveAtIngest)
        XCTAssertTrue(configuration.shouldKeep(title: "Still safe", durationSeconds: nil))
    }

    func testTurningFilteringOffResolvesZeroRuleError() {
        var configuration = EpisodeFilterConfiguration(
            isEnabled: true, mode: .keepMatching, rules: []
        )
        XCTAssertNotNil(configuration.validationMessage())

        configuration.isEnabled = false
        XCTAssertNil(configuration.validationMessage())
        XCTAssertTrue(configuration.shouldKeep(title: "Still safe", durationSeconds: nil))
    }

    func testConfigurationRoundTripsAsMirroredVersionedJSON() throws {
        let context = TestStore.freshContext()
        let store = AppSettingsStore(context: context)
        let feedURL = "HTTPS://Example.COM:443/feed.xml#old"
        let configuration = EpisodeFilterConfiguration(
            isEnabled: true,
            mode: .filterMatching,
            rules: [EpisodeFilterRule(name: "Segments", titlePattern: "*update*")]
        )

        try store.setEpisodeFilterConfiguration(configuration, forFeedURL: feedURL)
        XCTAssertEqual(store.episodeFilterConfiguration(forFeedURL: feedURL), configuration)
        XCTAssertFalse(
            AppSettingScope.isLocal(SettingsKey.episodeFilterConfiguration(feedURL: feedURL))
        )
        let rows = try context.fetch(FetchDescriptor<AppSetting>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows.first?.key,
            SettingsKey.episodeFilterConfigurationPrefix + "https://example.com/feed.xml"
        )
    }

    func testUnknownConfigurationVersionFailsOpen() throws {
        let raw = #"{"isEnabled":true,"mode":"keepMatching","rules":[],"version":99}"#
        let decoded = EpisodeFilterCodec.decode(raw)

        XCTAssertFalse(decoded.isEnabled)
        XCTAssertTrue(decoded.shouldKeep(title: "Anything", durationSeconds: nil))
    }

    func testMalformedConfigurationJSONFailsOpen() {
        let decoded = EpisodeFilterCodec.decode("{not-json")

        XCTAssertFalse(decoded.isEnabled)
        XCTAssertTrue(decoded.shouldKeep(title: "Anything", durationSeconds: nil))
    }

    private var durationConfiguration: EpisodeFilterConfiguration {
        EpisodeFilterConfiguration(
            isEnabled: true,
            mode: .keepMatching,
            rules: [EpisodeFilterRule(name: "Full show", minimumDurationMinutes: 45)]
        )
    }

    func testDurationSaveGateRefusesWhenNoneOfFiftyPreviewEpisodesHasDuration() {
        XCTAssertEqual(
            EpisodeFilterSaveAssessment.assess(
                configuration: durationConfiguration,
                previewDurations: Array(repeating: nil, count: 50)
            ),
            .refuseNoDuration
        )
    }

    func testDurationSaveGateRefusesWhenPreviewHasNoEpisodes() {
        XCTAssertEqual(
            EpisodeFilterSaveAssessment.assess(
                configuration: durationConfiguration,
                previewDurations: []
            ),
            .refuseNoDuration
        )
    }

    func testDurationSaveGateRequiresConfirmationForPartialCoverage() {
        XCTAssertEqual(
            EpisodeFilterSaveAssessment.assess(
                configuration: durationConfiguration,
                previewDurations: [3_000, nil]
            ),
            .confirmPartialDuration(reported: 1, total: 2)
        )
    }

    func testDurationSaveGateAllowsCompleteCoverage() {
        XCTAssertEqual(
            EpisodeFilterSaveAssessment.assess(
                configuration: durationConfiguration,
                previewDurations: [3_000, 3_600]
            ),
            .allowed
        )
    }

    func testDurationSaveGateIsInactiveWhenFilteringIsOff() {
        let configuration = EpisodeFilterConfiguration(
            isEnabled: false,
            mode: .keepMatching,
            rules: [EpisodeFilterRule(name: "Full show", minimumDurationMinutes: 45)]
        )

        XCTAssertEqual(
            EpisodeFilterSaveAssessment.assess(
                configuration: configuration,
                previewDurations: [nil, nil]
            ),
            .allowed
        )
    }

    func testFilterRuleSpeechPutsEnabledStateImmediatelyAfterName() {
        let rule = EpisodeFilterRule(
            name: "Full shows",
            isEnabled: true,
            titlePattern: "*show*",
            minimumDurationMinutes: 45
        )

        XCTAssertEqual(
            EpisodeFilterSpeech.ruleLabel(rule),
            "Full shows, enabled. Wildcard title, *show*. Duration at least 45 minutes."
        )
    }

    func testPreviewSpeechLeadsWithDecision() {
        XCTAssertEqual(
            EpisodeFilterSpeech.previewLabel(
                kept: false, title: "Short segment", durationSeconds: nil
            ),
            "Filtered, Short segment, duration unavailable."
        )
    }

    func testExistingApplicationSpeechReportsInboxQueueAndPlayingException() {
        XCTAssertEqual(
            EpisodeFilterSpeech.existingApplicationAnnouncement(
                ExistingEpisodeFilterReport(
                    evaluated: 5,
                    filtered: 3,
                    dismissedFromInbox: 2,
                    removedFromQueue: 1,
                    retainedCurrentlyPlaying: 1
                )
            ),
            "Episode filters saved and applied to existing episodes. 2 removed from the inbox. 1 removed from the queue. The currently playing episode stayed in the queue."
        )
    }

    func testApplyToExistingDismissesInboxAndDequeuesWithoutChangingPlayedState() async throws {
        let context = TestStore.freshContext()
        let feedURL = "https://example.com/existing-filter.xml"
        let podcast = Podcast(feedURL: feedURL, title: "Existing filter")
        context.insert(podcast)

        let filteredInbox = Episode(
            guid: "filtered-inbox", title: "Segment one", audioURL: "https://x/1.mp3"
        )
        filteredInbox.podcast = podcast
        let keptInbox = Episode(
            guid: "kept-inbox", title: "Full show", audioURL: "https://x/2.mp3"
        )
        keptInbox.podcast = podcast
        let filteredQueued = Episode(
            guid: "filtered-queued", title: "Segment two", audioURL: "https://x/3.mp3",
            status: .inQueue, inboxDismissed: true
        )
        filteredQueued.podcast = podcast
        let filteredQueueItem = QueueItem(episode: filteredQueued, position: 0)
        context.insert(filteredQueueItem)
        let keptQueued = Episode(
            guid: "kept-queued", title: "Full show two", audioURL: "https://x/4.mp3",
            status: .inQueue, inboxDismissed: true
        )
        keptQueued.podcast = podcast
        let keptQueueItem = QueueItem(episode: keptQueued, position: 1)
        context.insert(keptQueueItem)
        let filteredPlayed = Episode(
            guid: "filtered-played", title: "Segment three", audioURL: "https://x/5.mp3",
            status: .played, positionSeconds: 123, playedAt: .now
        )
        filteredPlayed.podcast = podcast
        for episode in [filteredInbox, keptInbox, filteredQueued, keptQueued, filteredPlayed] {
            context.insert(episode)
        }
        try context.save()

        let configuration = EpisodeFilterConfiguration(
            isEnabled: true,
            mode: .filterMatching,
            rules: [EpisodeFilterRule(name: "Segments", titlePattern: "Segment*")]
        )
        let maintenance = await EpisodeFilterMaintenance.makeBackground(
            modelContainer: TestStore.container
        )
        let report = try await maintenance.applyToExistingEpisodes(
            feedURL: feedURL,
            configuration: configuration
        )

        XCTAssertEqual(
            report,
            ExistingEpisodeFilterReport(
                evaluated: 5,
                filtered: 3,
                dismissedFromInbox: 2,
                removedFromQueue: 1,
                retainedCurrentlyPlaying: 0
            )
        )
        let verification = ModelContext(TestStore.container)
        let episodes = try verification.fetch(FetchDescriptor<Episode>())
        let byGUID = Dictionary(uniqueKeysWithValues: episodes.map { ($0.guid, $0) })
        XCTAssertTrue(try XCTUnwrap(byGUID["filtered-inbox"]).inboxDismissed)
        XCTAssertFalse(try XCTUnwrap(byGUID["kept-inbox"]).inboxDismissed)
        XCTAssertNil(try XCTUnwrap(byGUID["filtered-queued"]).queueItem)
        XCTAssertEqual(try XCTUnwrap(byGUID["filtered-queued"]).status, .newEpisode)
        XCTAssertNotNil(try XCTUnwrap(byGUID["kept-queued"]).queueItem)
        XCTAssertEqual(try XCTUnwrap(byGUID["filtered-played"]).status, .played)
        XCTAssertEqual(try XCTUnwrap(byGUID["filtered-played"]).positionSeconds, 123)
        let remainingQueue = try verification.fetch(
            FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.position)])
        )
        XCTAssertEqual(remainingQueue.map(\.position), [0])
    }

    func testApplyToExistingRetainsCurrentlyPlayingQueueEpisode() async throws {
        let context = TestStore.freshContext()
        let feedURL = "https://example.com/playing-filter.xml"
        let podcast = Podcast(feedURL: feedURL, title: "Playing filter")
        let episode = Episode(
            guid: "playing", title: "Segment playing", audioURL: "https://x/playing.mp3",
            status: .inQueue, positionSeconds: 42, inboxDismissed: true
        )
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        context.insert(QueueItem(episode: episode, position: 0))
        try LocalAppSettingIdentity.setValue(
            "\(feedURL)|playing",
            for: SettingsKey.lastPlayingEpisodeID,
            in: context
        )
        try context.save()

        let configuration = EpisodeFilterConfiguration(
            isEnabled: true,
            mode: .filterMatching,
            rules: [EpisodeFilterRule(name: "Segments", titlePattern: "Segment*")]
        )
        let maintenance = await EpisodeFilterMaintenance.makeBackground(
            modelContainer: TestStore.container
        )
        let report = try await maintenance.applyToExistingEpisodes(
            feedURL: feedURL,
            configuration: configuration
        )

        XCTAssertEqual(report.retainedCurrentlyPlaying, 1)
        XCTAssertEqual(report.removedFromQueue, 0)
        let verification = ModelContext(TestStore.container)
        let stored = try XCTUnwrap(verification.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertNotNil(stored.queueItem)
        XCTAssertEqual(stored.status, .inQueue)
        XCTAssertEqual(stored.positionSeconds, 42)
    }
}
