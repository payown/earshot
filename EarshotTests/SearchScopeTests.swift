import XCTest
import SwiftUI
@testable import Earshot

/// Tests for the search-scope split: the Library toolbar search is scoped to the
/// user's own content (`.library`) and never touches the directory, while the Add
/// Podcast flow's search is `.addPodcast` — podcast-focused (local podcasts plus
/// the iTunes directory, no episodes or bookmarks). Each scope's section set, the
/// directory request, the debounce task, and the "From the directory" section are
/// all driven by `scope` in ``SearchView``, so the stored `scope` and the section
/// flags it exposes are the single source of truth these tests pin down.
@MainActor
final class SearchScopeTests: XCTestCase {

    func testDefaultScopeIsAddPodcast() {
        // Existing call sites that don't pass a scope must keep searching the
        // directory, so the default must remain the directory-backed Add scope.
        let view = SearchView()
        XCTAssertEqual(view.scope, .addPodcast)
    }

    func testLibraryScopeIsStored() {
        let view = SearchView(scope: .library)
        XCTAssertEqual(view.scope, .library)
    }

    /// The search-first Add Podcast screen builds a `.addPodcast` SearchView with a
    /// title override and autofocus on. The stored scope must still be `.addPodcast`
    /// so episodes/bookmarks stay hidden and the directory stays searched. This pins
    /// the new configurable init the Library "+" entry depends on.
    func testSearchViewAddPodcastConfigKeepsScope() {
        let view = SearchView(scope: .addPodcast, title: "Add podcast", autoFocusSearch: true)
        XCTAssertEqual(view.scope, .addPodcast)
    }

    func testAddPodcastScopeIsStored() {
        let view = SearchView(scope: .addPodcast)
        XCTAssertEqual(view.scope, .addPodcast)
    }

    func testScopeCasesAreDistinct() {
        XCTAssertNotEqual(SearchScope.library, SearchScope.addPodcast)
    }

    /// The Add Podcast screen supplies its secondary add paths ("Add by RSS URL",
    /// "Import OPML file") via `SearchView`'s `headerContent` slot so they render as
    /// real `List` rows — the only placement VoiceOver reliably reaches while the
    /// `.searchable` field is focused and the keyboard is up. Passing header content
    /// must not change the stored scope (episodes/bookmarks stay hidden, directory
    /// stays searched). This pins the generic header-content init the fix depends on.
    func testSearchViewKeepsScopeWithHeaderContent() {
        let view = SearchView(scope: .addPodcast, title: "Add podcast", autoFocusSearch: true) {
            Text("Other ways to add")
        }
        XCTAssertEqual(view.scope, .addPodcast)
    }

    /// Callers that pass no header content (Library toolbar search, onboarding) infer
    /// an empty header so they're unaffected by the new slot. This guards the default
    /// `EmptyView` header so adding the slot didn't break the existing call sites.
    func testSearchViewDefaultsToEmptyHeaderContent() {
        let view = SearchView(scope: .library)
        XCTAssertEqual(view.scope, .library)
        XCTAssertTrue(type(of: view) == SearchView<EmptyView>.self)
    }

    // MARK: - Section sets

    /// The Library scope searches everything the user already has: podcasts,
    /// episodes, and bookmarks — and never reaches the directory.
    func testLibraryScopeShowsLocalSectionsAndNoDirectory() {
        let scope = SearchScope.library
        XCTAssertTrue(scope.showsPodcasts)
        XCTAssertTrue(scope.showsEpisodes)
        XCTAssertTrue(scope.showsBookmarks)
        XCTAssertFalse(scope.showsDirectory)
    }

    /// The Add-Podcast scope is podcast-focused: local matching podcasts plus the
    /// directory, but it deliberately excludes episodes and bookmarks so adding a
    /// show isn't cluttered with episode/bookmark noise.
    func testAddPodcastScopeShowsPodcastsAndDirectoryOnly() {
        let scope = SearchScope.addPodcast
        XCTAssertTrue(scope.showsPodcasts)
        XCTAssertTrue(scope.showsDirectory)
        XCTAssertFalse(scope.showsEpisodes, "Add-Podcast search must not show the episodes section")
        XCTAssertFalse(scope.showsBookmarks, "Add-Podcast search must not show the bookmarks section")
    }

    /// Only the Add scope reaches the network; the Library scope never does. Pinning
    /// this exclusivity keeps the directory request gated on the right scope.
    func testOnlyAddPodcastScopeReachesDirectory() {
        XCTAssertTrue(SearchScope.addPodcast.showsDirectory)
        XCTAssertFalse(SearchScope.library.showsDirectory)
    }
}

/// Tests for the shared ``AddPodcastOptions`` group used by both onboarding and the
/// Library tab's Add Podcast sheet. It must expose exactly the three add actions,
/// each wired to its own caller-supplied closure.
@MainActor
final class AddPodcastOptionsTests: XCTestCase {

    func testExposesAllThreeActions() {
        var searched = false
        var addedByURL = false
        var importedOPML = false

        let options = AddPodcastOptions(
            onSearch: { searched = true },
            onAddByURL: { addedByURL = true },
            onImportOPML: { importedOPML = true }
        )

        // Each closure is independent and fires only its own flag.
        options.onSearch()
        XCTAssertTrue(searched)
        XCTAssertFalse(addedByURL)
        XCTAssertFalse(importedOPML)

        options.onAddByURL()
        XCTAssertTrue(addedByURL)
        XCTAssertFalse(importedOPML)

        options.onImportOPML()
        XCTAssertTrue(importedOPML)
    }
}
