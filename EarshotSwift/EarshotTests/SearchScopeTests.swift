import XCTest
import SwiftUI
@testable import Earshot

/// Tests for the search-scope split: the Library toolbar search is scoped to the
/// user's own content (`.library`) and never touches the directory, while the Add
/// Podcast flow's search is `.everywhere`. The directory request, debounce task,
/// and "From the directory" section are all gated on `scope == .everywhere` in
/// ``SearchView``, so the stored `scope` is the single source of truth and is what
/// these tests pin down.
final class SearchScopeTests: XCTestCase {

    func testDefaultScopeIsEverywhere() {
        // Existing call sites that don't pass a scope must keep searching the
        // directory, so the default must remain `.everywhere`.
        let view = SearchView()
        XCTAssertEqual(view.scope, .everywhere)
    }

    func testLibraryScopeIsStored() {
        let view = SearchView(scope: .library)
        XCTAssertEqual(view.scope, .library)
    }

    func testEverywhereScopeIsStored() {
        let view = SearchView(scope: .everywhere)
        XCTAssertEqual(view.scope, .everywhere)
    }

    func testScopeCasesAreDistinct() {
        XCTAssertNotEqual(SearchScope.library, SearchScope.everywhere)
    }
}

/// Tests for the shared ``AddPodcastOptions`` group used by both onboarding and the
/// Library tab's Add Podcast sheet. It must expose exactly the three add actions,
/// each wired to its own caller-supplied closure.
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
