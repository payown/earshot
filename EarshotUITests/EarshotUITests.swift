import XCTest
import UIKit

@MainActor
final class EarshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // A landscape-specific test can leave CoreSimulator mid-rotation when
        // XCTest launches the next app instance. Most UI tests exercise the
        // conventional portrait baseline.
        XCUIDevice.shared.orientation = .portrait
    }

    func testWatchDownloadPickerOpensTwiceWithoutCrashing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15), app.debugDescription)
        settings.tap()

        let pickerLink = app.buttons["Apple Watch Downloads"]
        XCTAssertTrue(pickerLink.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<2 {
            pickerLink.tap()
            let pickerBar = app.navigationBars["Apple Watch Downloads"]
            XCTAssertTrue(pickerBar.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.buttons["Our Perspective"].waitForExistence(timeout: 5),
                          "The picker should list followed shows after loading")
            XCTAssertTrue(app.buttons["Technically Working"].exists)
            pickerBar.buttons["BackButton"].tap()
            XCTAssertTrue(pickerLink.waitForExistence(timeout: 5))
        }
    }

    func testIPadExposesNewWindowAction() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Multiple windows are an iPad feature")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "episodeList"]
        app.launch()

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15), app.debugDescription)
        settings.tap()
        let newWindow = app.buttons["Open another Earshot window"]
        XCTAssertTrue(newWindow.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testIPadLibraryKeepsPodcastSidebarWhileBrowsing() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Persistent Library sidebar requires an iPad layout")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()

        let firstShow = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Technically Working"
        )).firstMatch
        let secondShow = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Our Perspective"
        )).firstMatch
        XCTAssertTrue(firstShow.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(secondShow.exists)
        firstShow.tap()
        XCTAssertTrue(secondShow.waitForExistence(timeout: 5),
                      "The show list should remain beside the selected show")
        XCTAssertTrue(firstShow.isSelected, "The sidebar should expose its selected show")
        let episode = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "#170 – Turn the Right Knob"
        )).firstMatch
        for _ in 0..<5 where !episode.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(episode.waitForExistence(timeout: 5), app.debugDescription)
        episode.tap()
        XCTAssertTrue(app.descendants(matching: .any)["episode.detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Back to episodes"].exists)
        XCTAssertTrue(secondShow.exists, "Episode detail should keep the Library sidebar")
        app.buttons["Back to episodes"].tap()
        XCTAssertTrue(episode.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(firstShow.isSelected)
        secondShow.tap()
        XCTAssertTrue(firstShow.exists)
        XCTAssertTrue(app.navigationBars["Our Perspective"].waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertFalse(episode.exists, "Changing shows should replace the episode content")
        app.buttons["Inbox"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 5))
        app.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(secondShow.waitForExistence(timeout: 5))
        XCTAssertTrue(secondShow.isSelected, "Switching tabs should retain the selected show")
    }

    func testIPadSearchSwitchesPodcastDetails() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Search detail columns require an iPad layout")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        guard window.frame.width >= 800 else {
            throw XCTSkip("Search detail columns require a window at least 800 points wide")
        }
        let searchButton = app.buttons["Search your library"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 15), app.debugDescription)
        searchButton.tap()
        let field = app.searchFields["Search your library"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText("e")
        let firstResult = app.buttons["Technically Working, Michael Babcock & Damashe Thomas"]
        let secondSidebarShow = app.buttons["Our Perspective, 2 unplayed episodes, Kolby & Michael"]
        XCTAssertTrue(firstResult.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(secondSidebarShow.exists)
        firstResult.tap()
        let firstEpisode = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "#170 – Turn the Right Knob"
        )).firstMatch
        XCTAssertTrue(firstEpisode.waitForExistence(timeout: 5), app.debugDescription)
        secondSidebarShow.tap()
        XCTAssertTrue(secondSidebarShow.isSelected, "The sidebar selection should switch podcasts")
        XCTAssertTrue(firstEpisode.waitForNonExistence(timeout: 5),
                      "Switching shows must replace the episode data source")
    }

    func testIPadSearchQueryRestoresAfterPodcastDetail() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Search detail navigation requires an iPad layout")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        guard window.frame.width >= 800 else {
            throw XCTSkip("Search detail navigation requires a window at least 800 points wide")
        }
        app.buttons["Search your library"].tap()
        let field = app.searchFields["Search your library"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText("e")
        let firstResult = app.buttons.matching(NSPredicate(
            format: "label == %@", "Technically Working, Michael Babcock & Damashe Thomas"
        )).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 10), app.debugDescription)
        firstResult.tap()
        let detailBar = app.navigationBars["Technically Working"]
        XCTAssertTrue(detailBar.waitForExistence(timeout: 5), app.debugDescription)
        detailBar.buttons["BackButton"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(field.isHittable, "Back should restore the Library search field")
        XCTAssertEqual(field.value as? String, "e", "Back should preserve the Library query")
        field.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue + "pers")
        XCTAssertEqual(field.value as? String, "pers", "The restored Library query should be editable")
        XCTAssertTrue(firstResult.waitForNonExistence(timeout: 5),
                      "Editing the query should remove the old result")
        let secondResult = app.buttons.matching(NSPredicate(
            format: "label == %@", "Our Perspective, Kolby & Michael"
        )).firstMatch
        XCTAssertTrue(secondResult.waitForExistence(timeout: 5), app.debugDescription)
        secondResult.tap()
        XCTAssertTrue(app.navigationBars["Our Perspective"].waitForExistence(timeout: 5))
    }

    func testIPadLibraryVoiceOverReadsSelectedSidebarShow() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad, #available(iOS 27.0, *) else {
            throw XCTSkip("VoiceOver sidebar automation requires iPadOS 27")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()
        let show = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Technically Working"
        )).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 15), app.debugDescription)
        show.tap()
        XCTAssertTrue(show.isSelected)

        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { try? voiceOver.disable() }
        var speech: [String] = []
        for _ in 0..<60 {
            let utterance = try voiceOver.moveForward().utterance
            speech.append(utterance)
            if utterance.contains("Technically Working") { break }
        }
        let selection = try XCTUnwrap(speech.first(where: { $0.contains("Technically Working") }),
                                      "VoiceOver could not reach the selected show: \(speech)")
        XCTAssertTrue(selection.localizedCaseInsensitiveContains("selected"),
                      "VoiceOver should announce the selected show: \(speech)")
    }

    func testIPadMiniLibraryRemainsNavigableAtLargestText() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("This checks iPad Dynamic Type navigation")
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestScreenshotSeed", "-screenshotScreen", "library",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        let show = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Technically Working"
        )).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(show.isHittable, "The show row should remain reachable at large text")
        show.tap()
        XCTAssertTrue(app.navigationBars["Technically Working"].waitForExistence(timeout: 5),
                      app.debugDescription)
    }

    func testCompactLibraryCanReturnFromEpisodeToShows() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This checks the compact iPhone navigation path")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()

        let show = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Technically Working"
        )).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 15), app.debugDescription)
        show.tap()
        let episode = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "#170 – Turn the Right Knob"
        )).firstMatch
        for _ in 0..<5 where !episode.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(episode.waitForExistence(timeout: 5), app.debugDescription)
        episode.tap()
        XCTAssertTrue(app.descendants(matching: .any)["episode.detail"].waitForExistence(timeout: 5))
        app.buttons["Back to episodes"].tap()
        XCTAssertTrue(app.segmentedControls["Filter episodes"].waitForExistence(timeout: 5),
                      "Returning from details should restore the show episode list")
        let backToShows = app.descendants(matching: .any)["BackButton"].firstMatch
        XCTAssertTrue(backToShows.waitForExistence(timeout: 5), app.debugDescription)
        backToShows.tap()
        XCTAssertTrue(show.waitForExistence(timeout: 5))
    }

    func testEpisodeSelectionAndPlayAreSeparate() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "episodeList"]
        app.launch()

        let episode = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "#170 – Turn the Right Knob"
        )).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 15), app.debugDescription)
        episode.tap()
        XCTAssertTrue(app.descendants(matching: .any)["episode.detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Show notes"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Mini player, "
        )).firstMatch.exists, "Selecting an episode must not load playback")

        let play = app.buttons["episode.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5),
                      "Play should present the active player immediately")
        XCTAssertEqual(app.buttons["player.playPause"].label, "Pause")
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Mini player, "
        )).firstMatch.waitForExistence(timeout: 5), "Play must load the selected episode")
    }

    func testQueueEpisodeSelectionAndPlayAreSeparate() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "queue"]
        app.launch()

        let episode = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "#166 – If You Used a Passkey"
        )).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 15), app.debugDescription)
        episode.tap()
        XCTAssertTrue(app.descendants(matching: .any)["episode.detail"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Mini player, "
        )).firstMatch.exists)

        app.buttons["episode.detail.play"].tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["player.playPause"].label, "Pause")
    }

    func testQueueVoiceOverHasOneStopPerEpisode() throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("VoiceOver UI automation requires iOS 27")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "queue"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "#166 – If You Used a Passkey"
        )).firstMatch.waitForExistence(timeout: 15))

        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { try? voiceOver.disable() }

        // Drive real VoiceOver focus rather than inferring its order from the
        // XCTest element tree, which includes touch-only visual controls.
        var speech: [String] = []
        for _ in 0..<40 {
            let utterance = try voiceOver.moveForward().utterance
            speech.append(utterance)
            if utterance.contains("#165 – No Excuses Left") { break }
        }

        let firstIndex = try XCTUnwrap(speech.firstIndex(where: { $0.contains("#166 – If You Used a Passkey") }),
                                       "Queue's first episode was not reached: \(speech)")
        let secondIndex = try XCTUnwrap(speech.firstIndex(where: { $0.contains("#165 – No Excuses Left") }),
                                        "Queue's second episode was not reached: \(speech)")
        XCTAssertEqual(secondIndex, firstIndex + 1,
                       "Each Queue episode should be one VoiceOver stop: \(speech)")
    }

    func testSharedEpisodeRowVoiceOverHasOneStopPerEpisode() throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("VoiceOver UI automation requires iOS 27")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "episodeList"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "#170 – Turn the Right Knob"
        )).firstMatch.waitForExistence(timeout: 15), app.debugDescription)

        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { try? voiceOver.disable() }

        var speech: [String] = []
        for _ in 0..<40 {
            let utterance = try voiceOver.moveForward().utterance
            speech.append(utterance)
            if utterance.contains("#169 – Apple's Price Hikes") { break }
        }

        let firstIndex = try XCTUnwrap(speech.firstIndex(where: { $0.contains("#170 – Turn the Right Knob") }),
                                       "The first show episode was not reached: \(speech)")
        let secondIndex = try XCTUnwrap(speech.firstIndex(where: { $0.contains("#169 – Apple's Price Hikes") }),
                                        "The second show episode was not reached: \(speech)")
        XCTAssertEqual(secondIndex, firstIndex + 1,
                       "Each shared episode row should be one VoiceOver stop: \(speech)")
    }

    func testLibraryEpisodeRowsExposeInboxAndQueuePlacementInOneLabel() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "episodeList"]
        app.launch()

        let inbox = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "In Inbox, #169 – Apple's Price Hikes"
        )).firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 15), app.debugDescription)
        let queued = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "In Queue, #166 – If You Used a Passkey"
        )).firstMatch
        // The List is lazy; #166 starts below the visible #169 row.
        for _ in 0..<4 where !queued.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(queued.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(queued.label.contains("In Inbox"), "Queue placement should win over Inbox")
    }

    func testLibrarySearchEpisodeResultsExposePlacementInOneRow() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()

        let searchButton = app.buttons["Search your library"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 15), app.debugDescription)
        searchButton.tap()
        let field = app.searchFields["Search your library"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText("Price Hikes")
        let inbox = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "In Inbox, #169 – Apple's Price Hikes"
        )).firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 15), app.debugDescription)

        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Price Hikes".count) + "Passkey")
        let queued = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "In Queue, #166 – If You Used a Passkey"
        )).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(queued.label.contains("In Inbox"), "The Queue takes priority in Search")
    }

    func testQuickActionsDownloadSettingNamesBothOutcomes() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15), app.debugDescription)
        settingsTab.tap()
        let quickActions = app.buttons["Quick Actions"]
        for _ in 0..<5 where !quickActions.isHittable { app.swipeUp() }
        XCTAssertTrue(quickActions.waitForExistence(timeout: 5), app.debugDescription)
        quickActions.tap()
        let download = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@", "Download / Remove Download, enabled"
        ))
        XCTAssertTrue(download.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testInboxVoiceOverHasOneStopPerEpisode() throws {
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("VoiceOver UI automation requires iOS 27")
        }
        let app = XCUIApplication()
        // Seed while Queue is active, then enter Inbox after launch services
        // finish. An Inbox-first screenshot launch can query before the DEBUG
        // fixture is seeded and display a stale empty snapshot.
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "queue"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "#166 – If You Used a Passkey"
        )).firstMatch.waitForExistence(timeout: 15))
        app.buttons["Inbox"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "#169 – Apple's Price Hikes"
        )).firstMatch.waitForExistence(timeout: 15), app.debugDescription)

        let voiceOver = XCUIDevice.shared.voiceOverService
        try voiceOver.enable()
        defer { try? voiceOver.disable() }

        var speech: [String] = []
        for _ in 0..<40 {
            let utterance = try voiceOver.moveForward().utterance
            speech.append(utterance)
            if utterance.contains("#167 – We're Going to Atlanta") { break }
        }

        let firstIndex = try XCTUnwrap(speech.firstIndex(where: { $0.contains("#169 – Apple's Price Hikes") }),
                                       "Inbox's first episode was not reached: \(speech)")
        let secondIndex = try XCTUnwrap(speech.firstIndex(where: { $0.contains("#167 – We're Going to Atlanta") }),
                                        "Inbox's second episode was not reached: \(speech)")
        XCTAssertEqual(secondIndex, firstIndex + 1,
                       "Each Inbox episode should be one VoiceOver stop: \(speech)")
    }

    func testFolderMembershipPickerKeepsSelectionCurrent() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "episodeList"]
        app.launch()
        let settings = app.buttons["Podcast settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let manage = app.buttons["Manage folders…"].firstMatch
        for _ in 0..<12 where !manage.isHittable { app.swipeUp() }
        XCTAssertTrue(manage.isHittable, app.debugDescription)
        manage.tap()
        let create = app.buttons["New folder…"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Picker performance test")
        app.alerts.buttons["Create"].tap()
        let folder = app.buttons["Picker performance test"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertTrue(folder.isSelected)
        folder.tap()
        expectation(for: NSPredicate(format: "selected == false"), evaluatedWith: folder)
        waitForExpectations(timeout: 5)
        folder.tap()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: folder)
        waitForExpectations(timeout: 5)
    }

    func testEpisodeSortIsIndependentForEachPodcast() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()
        func openPodcast(_ title: String) {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        }
        openPodcast("Technically Working")
        let oldest = app.buttons["Sort oldest to newest"]
        let newest = app.buttons["Sort newest to oldest"]
        XCTAssertTrue(oldest.waitForExistence(timeout: 5))
        oldest.tap()
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        app.navigationBars.buttons["Library"].tap()
        openPodcast("Our Perspective")
        XCTAssertTrue(oldest.waitForExistence(timeout: 5), "Another podcast must retain newest-first")
        app.navigationBars.buttons["Library"].tap()
        openPodcast("Technically Working")
        XCTAssertTrue(newest.waitForExistence(timeout: 5), "Returning must restore this podcast's oldest-first choice")
    }

    func testKeepFinishedQueuePreference() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Settings"].tap()
        let playback = app.buttons["Playback"]
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        playback.tap()
        let toggle = app.switches["Keep finished episodes in Queue"].firstMatch
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testPlaybackPositionAdjustmentSetting() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Settings"].tap()
        let playback = app.buttons["Playback"]
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        playback.tap()

        let adjustment = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Playback position adjustment")
        ).firstMatch
        func revealAdjustment() {
            for _ in 0..<6 where !adjustment.isHittable { app.swipeUp() }
            XCTAssertTrue(adjustment.isHittable, app.debugDescription)
        }
        revealAdjustment()
        XCTAssertEqual(adjustment.value as? String, "Automatic")
        // Tap the visible picker to open its native menu; the accessibility
        // representation is an adjustable element for VoiceOver.
        adjustment.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let fiveMinutes = app.buttons["5 minutes"].firstMatch
        XCTAssertTrue(fiveMinutes.waitForExistence(timeout: 5))
        fiveMinutes.tap()
        XCTAssertEqual(adjustment.value as? String, "5 minutes")

        app.navigationBars.buttons["Settings"].tap()
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        playback.tap()
        revealAdjustment()
        XCTAssertEqual(adjustment.value as? String, "5 minutes")
    }

    func testHomeScreenBadgeOptInAndOptOut() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Settings"].tap()
        let appearance = app.buttons["Appearance"]
        for _ in 0..<4 where !appearance.isHittable { app.swipeUp() }
        XCTAssertTrue(appearance.waitForExistence(timeout: 5), app.debugDescription)
        appearance.tap()
        let toggle = app.switches["Badge downloaded unplayed episodes"].firstMatch
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(toggle.value as? String, "0")
        // The native switch AX frame includes the two-line label; tap its trailing control.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 10)
        // The native switch AX frame includes the two-line label; tap its trailing control.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testLibraryCaughtUpFilterAndDeferredTabReentry() {
        let app = XCUIApplication()
        // The existing folder-run fixture supplies a followed podcast with no
        // episodes, alongside the ordinary fixtures with unheard episodes.
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library", "-folderRunTest"]
        app.launch()
        let options = app.buttons["Library options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 15))
        let caughtUp = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Folder test show, 0 unplayed episodes"
        )).firstMatch
        XCTAssertTrue(caughtUp.waitForExistence(timeout: 10), app.debugDescription)
        options.tap()
        let toggle = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Hide caught-up podcasts"
        )).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        toggle.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: caughtUp)
        waitForExpectations(timeout: 5)
        app.tabBars.buttons["Queue"].tap()
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertFalse(caughtUp.exists)
        options.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(caughtUp.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testFeedFailureOpensPodcastAndRetryRecoversWithoutNewEpisodes() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "feedRefresh"]
        app.launch()
        let retry = app.buttons["Retry feed check for Feed retry test"]
        func reveal(_ element: XCUIElement) {
            for _ in 0..<12 where !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.isHittable, app.debugDescription)
        }
        XCTAssertTrue(app.navigationBars["Feed Refresh"].waitForExistence(timeout: 15))
        reveal(retry)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Feed retry test. Refresh failed.")).firstMatch
        XCTAssertTrue(row.isHittable, app.debugDescription)
        row.tap()
        XCTAssertTrue(app.navigationBars["Feed retry test"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons["Feed Refresh"].tap()
        reveal(retry)
        retry.tap()
        let status = app.staticTexts["feedRetryStatus"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "503"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        reveal(retry)
        XCTAssertTrue(retry.isEnabled)
        retry.tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Feed check succeeded. No new episodes found."), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(retry.exists, app.debugDescription)
        XCTAssertFalse(row.exists)
    }

    func testSleepTimerInteractionAcrossSheets() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying"]
        app.launch()
        let more = app.buttons["More options"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        func reveal(_ element: XCUIElement) {
            let list = app.collectionViews.firstMatch
            for _ in 0..<12 {
                let top = app.navigationBars["More options"].frame.maxY + 8
                let bottom = app.buttons["Done"].frame.minY - 8
                if element.exists, element.isHittable, element.frame.minY >= top, element.frame.maxY <= bottom { return }
                let upwards = !element.exists || element.frame.maxY > bottom
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upwards ? 0.75 : 0.35))
                    .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upwards ? 0.35 : 0.75)))
            }
        }
        let reset = app.switches["Reset sleep timer on interaction"]
        reveal(reset)
        XCTAssertTrue(reset.isHittable)
        XCTAssertEqual(reset.value as? String, "0")
        reset.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(reset.value as? String, "1")
        let picker = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Sleep timer")).firstMatch
        reveal(picker)
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        app.buttons["5 minutes"].tap()
        let extend = app.buttons["Extend by 5 minutes"]
        reveal(extend)
        XCTAssertTrue(extend.isHittable)
        extend.tap()
        let remaining = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Sleep timer remaining")).firstMatch
        XCTAssertTrue((remaining.value as? String ?? "").contains("10 minutes"))
        app.buttons["Done"].tap()
        more.tap()
        reveal(remaining)
        XCTAssertTrue((remaining.value as? String ?? "").contains("5 minutes"))
        XCTAssertEqual(reset.value as? String, "1")
        let cancel = app.buttons["Cancel sleep timer"]
        reveal(cancel)
        cancel.tap()
        XCTAssertFalse(app.buttons["Cancel sleep timer"].exists)
    }

    func testCustomSpeedAndMiniPlayerLabel() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying"]
        app.launch()
        let speed = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Playback speed")).firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 10))
        XCTAssertNotEqual(speed.elementType, .button, "Playback speed must remain an adjustable element for VoiceOver rate feedback")
        XCTAssertFalse((speed.value as? String ?? "").isEmpty, "The initial speed must have a spoken value before playback")
        speed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let input = app.textFields["Custom playback speed"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        for _ in 0..<4 where !input.isHittable { app.swipeUp() }
        input.tap()
        let existing = input.value as? String ?? ""
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "0.98")
        let apply = app.buttons["Apply custom speed"]
        for _ in 0..<4 where !apply.isHittable { app.swipeUp() }
        apply.tap()
        // iOS 27 can dismiss the custom-speed sheet when Apply is pressed.
        // Earlier systems leave Done visible; both return to the same player.
        let done = app.buttons["Done"]
        if done.exists { done.tap() }
        XCTAssertTrue(speed.waitForExistence(timeout: 5))
        XCTAssertTrue((speed.value as? String ?? "").contains("0.98"))
        app.buttons["Close player"].tap()
        let miniPlayer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Mini player, ")).firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(miniPlayer.label.count, "Mini player, ".count)
        miniPlayer.tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 5))
    }

    func testFolderRunPreparesHistoryConfirmsLargeCountAndCanBeCancelled() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library", "-folderRunTest"]
        app.launch()
        let folders = app.buttons["Folders"].firstMatch
        XCTAssertTrue(folders.waitForExistence(timeout: 10))
        folders.tap()
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Folder path: Backlog test")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription)
        folder.tap()
        app.buttons["Folder listening actions"].tap()
        app.buttons["Play unplayed oldest first"].firstMatch.tap()
        let prepare = app.buttons["Check feeds and prepare"].firstMatch
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        prepare.tap()
        let confirmation = app.staticTexts["Play 60 unplayed episodes from Backlog test, oldest first?"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 20))
        let deferPlayback = app.buttons["Not now"].firstMatch
        XCTAssertTrue(deferPlayback.waitForExistence(timeout: 5), app.debugDescription)
        deferPlayback.tap()
        let cancel = app.buttons["Cancel folder run"].firstMatch
        for _ in 0..<4 where !cancel.isHittable { app.swipeUp() }
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        for _ in 0..<4 { app.swipeDown() }
        let cancelled = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@ OR label CONTAINS %@", "Cancelled", "Cancelled")).firstMatch
        XCTAssertTrue(cancelled.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Resume folder run"].exists)
    }

    func testDownloadActivityUpdatesAfterDelayedFailureAndOffersBoundedRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "downloads", "-downloadActivityTest"]
        app.launch()
        let activity = app.buttons["Download activity"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.tap()
        let summary = app.staticTexts["downloadActivitySummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let failure = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "failed 2", "Downloading 0")
        expectation(for: failure, evaluatedWith: summary)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(summary.isHittable, "The current status should be available to read directly")
        XCTAssertFalse(app.buttons["Read download status"].exists)
        app.buttons["Retry failed downloads"].tap()
        let retry = app.buttons["Retry 2 downloads"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("failed 2"), "Invalid fixture media stays visibly failed after retry")
        XCTAssertTrue(app.buttons["Retry download for Failed test episode"].exists)
    }

    func testDownloadActivityWithLargeLibrarySupportsFilteringPagingAndNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "settings",
                               "-largeDownloadActivityTest"]
        app.launch()
        let activity = app.buttons["Download activity"].firstMatch
        for _ in 0..<8 where !activity.isHittable { app.swipeUp() }
        XCTAssertTrue(activity.waitForExistence(timeout: 30), app.debugDescription)
        activity.tap()

        let summary = app.staticTexts["downloadActivitySummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 30), app.debugDescription)
        let totals = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
                                 "Downloading 500", "waiting for Wi-Fi 500", "failed 500", "downloaded 500")
        expectation(for: totals, evaluatedWith: summary)
        waitForExpectations(timeout: 30)

        let completed = app.switches["Include completed downloads"]
        XCTAssertTrue(completed.waitForExistence(timeout: 10), app.debugDescription)
        let firstFailed = app.staticTexts["Large Failed episode 0000"]
        let firstCompleted = app.staticTexts["Large Completed episode 0000"]
        XCTAssertTrue(firstFailed.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(firstCompleted.exists)
        // SwiftUI exposes a labeled wrapper around the native switch. Tap the
        // nested control: the wrapper's center is over the text, not the switch.
        let completedControl = completed.switches.firstMatch
        XCTAssertTrue(completedControl.exists, app.debugDescription)
        completedControl.tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: completed)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(firstCompleted.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(firstFailed.exists)
        completedControl.tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: completed)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(firstFailed.waitForExistence(timeout: 20), app.debugDescription)

        let showMore = app.buttons["Show more download requests"]
        for _ in 0..<30 where !showMore.isHittable { app.swipeUp() }
        XCTAssertTrue(showMore.isHittable, app.debugDescription)
        showMore.tap()
        let nextPage = app.staticTexts["Large Failed episode 0050"]
        for _ in 0..<5 where !nextPage.exists { app.swipeUp() }
        XCTAssertTrue(nextPage.waitForExistence(timeout: 20), app.debugDescription)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(activity.waitForExistence(timeout: 15), app.debugDescription)
        activity.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 30), app.debugDescription)
        let retry = app.buttons["Retry failed downloads"]
        XCTAssertTrue(retry.isHittable, app.debugDescription)
        retry.tap()
        XCTAssertTrue(app.buttons["Retry 50 downloads"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testWorkflowGuideIsAvailableFromDownloadSettingsAtLargestText() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "settings",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let guide = app.buttons["Inbox, Queue, and Downloads guide"].firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        guide.tap()
        XCTAssertTrue(app.navigationBars["Listening workflow guide"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What each screen is for"].firstMatch.exists)
        let inbox = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox helps you review")).firstMatch
        XCTAssertTrue(inbox.exists)
        XCTAssertTrue(inbox.isHittable)
    }

    func testPodcastSettingsUnfollowConfirmsCancelsAndReturnsToLibrary() {
        verifyPodcastSettingsUnfollow(largeText: false)
    }

    func testPodcastSettingsUnfollowAtLargestText() {
        verifyPodcastSettingsUnfollow(largeText: true)
    }

    private func verifyPodcastSettingsUnfollow(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "episodeList"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let settings = app.buttons["Podcast settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let unfollow = app.buttons["Unfollow"].firstMatch
        let form = app.collectionViews.firstMatch
        for _ in 0..<16 {
            if unfollow.exists, unfollow.isHittable,
               unfollow.frame.maxY < app.frame.maxY - 35,
               unfollow.frame.minY > app.navigationBars["Podcast Settings"].frame.maxY { break }
            form.swipeUp()
        }
        XCTAssertTrue(unfollow.isHittable)
        XCTAssertGreaterThanOrEqual(unfollow.frame.height, 44)
        unfollow.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Podcast Settings"].exists)
        XCTAssertTrue(unfollow.isHittable)
        unfollow.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        app.alerts.buttons["Unfollow"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        // Library may be exposed underneath the dismissing sheet before its
        // transition completes. Wait for both outgoing surfaces to disappear.
        XCTAssertTrue(app.navigationBars["Podcast Settings"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Podcast settings"].waitForNonExistence(timeout: 5))
    }

    func testPodcastNameEditorSavesAndRestoresPublisherName() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "episodeList"]
        app.launch()
        let settings = app.buttons["Podcast settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let rename = app.buttons["Rename podcast"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        let originalName = rename.value as? String
        rename.tap()
        let field = app.textFields["Podcast name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "Personal Podcast")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertEqual(rename.value as? String, "Personal Podcast")
        rename.tap()
        app.buttons["Restore original name"].firstMatch.tap()
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertEqual(rename.value as? String, originalName)
    }

    func testPlayerTransportActionsFillTopRowWidth() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying",
            "-playerTransportActionLayoutTest"
        ]
        app.launch()

        let back = app.buttons["player.transportAction.skipBack120"]
        let forward = app.buttons["player.transportAction.skipForward300"]
        let position = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertTrue(forward.exists)
        XCTAssertTrue(position.exists)
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(forward.isHittable)
        XCTAssertEqual((back.frame.midX + forward.frame.midX) / 2, position.frame.midX, accuracy: 2,
                       "The action row should center within the available player controls")
        XCTAssertEqual(back.frame.minX, position.frame.minX, accuracy: 4,
                       "The first action should align with the leading edge of the player controls")
        XCTAssertEqual(forward.frame.maxX, position.frame.maxX, accuracy: 4,
                       "The last action should align with the trailing edge of the player controls")
        XCTAssertLessThan(back.frame.maxY, position.frame.minY,
                          "The configured actions should sit in one row above the position slider")
    }

    func testPlayerTransportActionRowScrollsWhenItOverflows() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying",
            "-playerTransportActionLayoutTest", "-playerTransportActionOverflowTest",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        let row = app.scrollViews["player.transportActions"]
        let lastAction = app.buttons["player.transportAction.skipBack10"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(lastAction.waitForExistence(timeout: 5))
        row.swipeLeft()
        XCTAssertTrue(lastAction.isHittable)
        XCTAssertGreaterThanOrEqual(lastAction.frame.minY, row.frame.minY - 1)
        XCTAssertLessThanOrEqual(lastAction.frame.maxY, row.frame.maxY + 1)
    }

    func testAnchoredPlayerStabilityAndSliderEdges() { verifyAnchoredPlayer(largeText: false) }
    func testAnchoredPlayerStabilityAtLargestText() { verifyAnchoredPlayer(largeText: true) }

    func testPlayerTransportRemainsReachableInLandscape() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying"]
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()

        let play = app.buttons["player.playPause"]
        let position = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(play.isHittable)
        XCTAssertTrue(position.isHittable)
        XCTAssertTrue(app.buttons["Close player"].isHittable)
        XCTAssertTrue(app.buttons["More options"].isHittable)
    }

    private func verifyAnchoredPlayer(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying", "-playerLayoutTransition"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let play = app.buttons["player.playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let position = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        let notes = app.buttons["Show notes"]
        let route = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "AirPlay")).firstMatch
        let controls = [position, app.buttons["player.gobackward"], play, app.buttons["player.goforward"], route, notes]
        let initial = controls.map(\.frame)
        XCTAssertGreaterThan(position.frame.height, 55.99,
                                    "The accessibility focus frame should retain its 56-point target within floating-point rounding")
        XCTAssertEqual(position.frame.midX, play.frame.midX, accuracy: 2,
                       "VoiceOver's playback-position focus frame should span the transport center within the safe area")
        XCTAssertTrue(play.isHittable)
        XCTAssertLessThanOrEqual(play.frame.maxY, app.frame.maxY)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Episode artwork")).firstMatch.exists)
        XCTAssertTrue(notes.isEnabled)
        XCTAssertEqual(app.buttons.matching(identifier: "Show notes").count, 1)
        XCTAssertGreaterThanOrEqual(route.frame.height, 44)
        XCTAssertGreaterThanOrEqual(notes.frame.height, 56)
        XCTAssertGreaterThan(route.frame.minY, play.frame.maxY)
        XCTAssertGreaterThan(notes.frame.minY, play.frame.maxY)
        XCTAssertLessThanOrEqual(position.frame.maxY, play.frame.minY)
        XCTAssertFalse(route.frame.intersects(notes.frame))
        XCTContext.runActivity(named: "Player frames AX5=\(largeText): \(controls.map { NSCoder.string(for: $0.frame) }.joined(separator: "; "))") { _ in }
        let prior = position.value as? String
        position.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.08)).tap()
        XCTAssertNotEqual(position.value as? String, prior)
        let first = position.value as? String
        position.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.92)).tap()
        XCTAssertNotEqual(position.value as? String, first)
        // Changes arrive after the initial measurements, without reopening the sheet.
        let changed = app.scrollViews["player.episodeContent"].staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A long episode title")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 20))
        for (control, rect) in zip(controls, initial) {
            XCTAssertEqual(control.frame.minY, rect.minY, accuracy: 1)
            XCTAssertEqual(control.frame.height, rect.height, accuracy: 1)
        }
        let episodeContent = app.scrollViews["player.episodeContent"]
        for _ in 0..<12 where !changed.isHittable {
            // Short, directed drags reveal a tall heading without flicking past
            // it in a small viewport. Pause before release to avoid momentum.
            let direction = changed.frame.midY > episodeContent.frame.midY ? -0.3 : 0.3
            episodeContent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1,
                       thenDragTo: episodeContent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 + direction)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(changed.isHittable, app.debugDescription)
        for (control, rect) in zip(controls, initial) {
            XCTAssertEqual(control.frame.minY, rect.minY, accuracy: 1)
        }
        XCTAssertTrue(app.buttons["More options"].isHittable)
        XCTAssertTrue(app.buttons["Close player"].isHittable)
        XCTAssertFalse(position.frame.intersects(play.frame))
        XCTAssertTrue(notes.exists)
        XCTAssertFalse(notes.isEnabled)
        XCTAssertGreaterThan(notes.frame.minY, play.frame.maxY)
        XCTAssertLessThan(notes.frame.maxY, app.frame.maxY)
        let separateDetails = app.scrollViews["player.details"].exists
        let scroll = separateDetails ? app.scrollViews["player.details"] : episodeContent
        let extend = scroll.buttons["Extend sleep timer by 5 minutes"]
        for _ in 0..<20 {
            if extend.exists && extend.isHittable && extend.frame.maxY <= scroll.frame.maxY { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(extend.isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(extend.frame.maxY, scroll.frame.maxY)
        if separateDetails {
            XCTAssertGreaterThanOrEqual(scroll.frame.minY, notes.frame.maxY)
        }
        XCTAssertLessThanOrEqual(episodeContent.frame.maxY, position.frame.minY)
        XCTAssertEqual(play.frame.minY, initial[2].minY, accuracy: 1)
        for control in [app.buttons["Close player"], app.buttons["More options"]] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
    }

    func testPlayerBottomRowOpensNotesAndExposesNativeAudioRouteButton() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying"]
        app.launch()
        let notes = app.buttons["Show notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
        XCTAssertTrue(app.navigationBars["Show notes"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let route = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "AirPlay")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        let nativeRouteButton = app.buttons["AirPlay"].firstMatch
        XCTAssertTrue(nativeRouteButton.isHittable)
        XCTAssertGreaterThanOrEqual(nativeRouteButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(nativeRouteButton.frame.height, 44)
        XCTAssertLessThan(nativeRouteButton.frame.maxX, notes.frame.minX)
        XCTAssertLessThan(nativeRouteButton.frame.maxY, app.frame.maxY)
        app.buttons["Close player"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Mini player, ")).firstMatch.tap()
        XCTAssertTrue(app.buttons["AirPlay"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["AirPlay"].firstMatch.isHittable)
    }

    func testPlayerOptionsAndTouchTargets() {
        verifyPlayerOptionsAndTargets(largeText: false)
    }

    func testPlayerOptionsAndTouchTargetsAtLargestText() {
        verifyPlayerOptionsAndTargets(largeText: true)
    }

    private func verifyPlayerOptionsAndTargets(largeText: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let more = app.buttons["More options"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Player options"].exists)
        XCTAssertFalse(app.buttons["Episode actions"].exists)
        let back = app.buttons["player.gobackward"]
        let forward = app.buttons["player.goforward"]
        let play = app.buttons["player.playPause"]
        for (control, minimum) in [(more, 44.0), (back, 64.0), (play, 80.0), (forward, 64.0)] {
            XCTAssertGreaterThanOrEqual(control.frame.width + 0.01, minimum)
            XCTAssertGreaterThanOrEqual(control.frame.height + 0.01, minimum)
            XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.width)
        }
        XCTAssertFalse(back.frame.intersects(play.frame))
        XCTAssertFalse(play.frame.intersects(forward.frame))
        // Measure the full player, not the mini bar behind its sheet.
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.85)).tap()
        XCTAssertTrue(app.navigationBars["More options"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["Done"].frame.height, 44)
        let mark = app.buttons["Mark as played"].firstMatch
        for _ in 0..<6 where !mark.isHittable { app.swipeUp() }
        XCTAssertTrue(mark.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "Mark as played").count, 1)
        let bookmarks = app.buttons["Bookmarks"].firstMatch
        // Hittable can also include a row clipped UNDER the navigation bar.
        // Large flicks can overshoot Bookmarks, placing its tap center in the
        // header. Use short, directed drags to reveal the entire target.
        let optionsList = app.collectionViews.firstMatch
        let navigationBar = app.navigationBars["More options"]
        for _ in 0..<12 {
            let top = navigationBar.frame.maxY + 4
            let bottom = app.buttons["Done"].frame.minY - 4
            if bookmarks.isHittable && bookmarks.frame.minY >= top && bookmarks.frame.maxY <= bottom { break }
            let direction = bookmarks.exists && bookmarks.frame.minY < top ? 0.25 : -0.25
            optionsList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1,
                       thenDragTo: optionsList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 + direction)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(bookmarks.isHittable)
        XCTAssertGreaterThanOrEqual(bookmarks.frame.minY, navigationBar.frame.maxY)
        XCTAssertLessThanOrEqual(bookmarks.frame.maxY, app.buttons["Done"].frame.minY)
        bookmarks.tap()
        XCTAssertTrue(app.navigationBars["Bookmarks"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testShortcutsGuideIsReachableFromSiriSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "queue"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let settings = app.buttons["Siri and Search"].firstMatch
        for _ in 0..<5 where !settings.isHittable { app.swipeUp() }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        app.buttons["Shortcuts guide"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Shortcuts guide"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready to use"].firstMatch.exists)
    }

    func testQueueClearRequiresConfirmationAndCancelPreservesQueue() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "queue"]
        app.launch()
        let options = app.buttons["Queue options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 5), app.debugDescription)
        library.tap()
        app.buttons["Queue"].firstMatch.tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        let clearQueue = app.buttons["Clear queue"].firstMatch
        func openClearConfirmation() {
            options.tap()
            if !clearQueue.waitForExistence(timeout: 5) {
                // System menus occasionally dismiss during a tab transition
                // on the CI simulator; retry the actual menu presentation once.
                options.tap()
            }
            XCTAssertTrue(clearQueue.waitForExistence(timeout: 5), app.debugDescription)
            clearQueue.tap()
        }
        openClearConfirmation()
        let clear = app.buttons["Clear entire Queue"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(clear.exists)
        openClearConfirmation()
        clear.tap()
        XCTAssertTrue(app.staticTexts["Queue is empty"].firstMatch.waitForExistence(timeout: 5))
    }

    func testSeededLibraryLaunchAndTabNavigationSmoke() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestScreenshotSeed",
            "-screenshotScreen", "library",
        ]

        app.launch()

        // TabView is exposed as a tab bar on iPhone and as adaptive buttons on
        // iPad. Query the button directly so this smoke test covers both forms.
        let libraryTab = app.buttons["Library"].firstMatch
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10))
        XCTAssertTrue(libraryTab.isSelected)

        let seededPodcast = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Technically Working")
        ).firstMatch
        XCTAssertTrue(
            seededPodcast.waitForExistence(timeout: 10),
            "The deterministic screenshot fixture should render a Library podcast."
        )

        let inboxTab = app.buttons["Inbox"].firstMatch
        XCTAssertTrue(inboxTab.exists)
        inboxTab.tap()

        let seededInboxEpisode = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Apple's Price Hikes")
        ).firstMatch
        XCTAssertTrue(
            seededInboxEpisode.waitForExistence(timeout: 5),
            "Screenshot-mode maintenance must not expire deterministic Inbox fixtures."
        )

        let queueTab = app.buttons["Queue"].firstMatch
        XCTAssertTrue(queueTab.exists)
        queueTab.tap()

        XCTAssertTrue(queueTab.isSelected)
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 5))
    }

    func testPersonalAudioIsFirstLibraryDestinationAndShowsItsEmptyStateAndAddAction() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "library"]
        app.launch()

        let personalAudio = app.buttons["Personal Audio"].firstMatch
        let podcast = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Technically Working")).firstMatch
        XCTAssertTrue(personalAudio.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(podcast.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThan(personalAudio.frame.minY, podcast.frame.minY)
        XCTAssertEqual(personalAudio.value as? String, "0 items")

        personalAudio.tap()
        XCTAssertTrue(app.navigationBars["Personal Audio"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Add audio files from Files to listen to them in Earshot."].exists)
        let add = app.buttons["Add to Earshot"].firstMatch
        XCTAssertTrue(add.exists)
    }

    func testAddPodcastSearchAndCategoryLandingOrder() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestScreenshotSeed",
            "-screenshotScreen", "library",
        ]
        app.launch()

        let addPodcast = app.buttons["Discover podcasts"].firstMatch
        XCTAssertTrue(addPodcast.waitForExistence(timeout: 10))
        addPodcast.tap()

        XCTAssertTrue(app.navigationBars["Discover podcasts"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        let browse = app.buttons["Browse categories"].firstMatch
        let rss = app.buttons["Add by RSS URL"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        XCTAssertTrue(rss.waitForExistence(timeout: 5))
        XCTAssertLessThan(search.frame.minY, browse.frame.minY)
        XCTAssertLessThan(browse.frame.minY, rss.frame.minY)

        browse.tap()
        XCTAssertTrue(app.navigationBars["Browse categories"].waitForExistence(timeout: 5))

        let fiction = app.buttons["Fiction"].firstMatch
        XCTAssertTrue(fiction.waitForExistence(timeout: 5))
        fiction.tap()
        XCTAssertTrue(app.buttons["Top Fiction shows"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Comedy Fiction"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Drama"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Science Fiction"].firstMatch.exists)
    }
    func testPlayerQueueActionsRemainAvailableInVisibleMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestScreenshotSeed", "-screenshotScreen", "nowPlaying"]
        app.launch()
        let actions = app.buttons["More options"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        let skipBack = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip back")).firstMatch
        let skipForward = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip forward")).firstMatch
        XCTAssertTrue(skipBack.exists)
        XCTAssertTrue(skipForward.exists)
        actions.tap()
        XCTAssertTrue(app.buttons["Previous in Queue"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Next in Queue"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Mark as played and next in Queue"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Mark as played"].firstMatch.exists)
    }

}
