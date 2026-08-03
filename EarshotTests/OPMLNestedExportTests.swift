import XCTest
import SwiftData
@testable import Earshot

/// Covers the nested OPML export (folders phase 3, #764): the pure
/// ``OPMLDocument/export(folders:unfiled:)`` tree emitter, the
/// ``FolderRepository/opmlExportString()`` builder that feeds it from SwiftData,
/// and the subscribe-to-folder offer decision. Round-trips assert through the same
/// ``OPMLDocument/groups(from:)`` path the app's OPML import uses, so the structure
/// a user exports is exactly what a re-import reconstructs.
@MainActor
final class OPMLNestedExportTests: XCTestCase {

    // MARK: Helpers

    private func feed(_ name: String) -> OPMLDocument.OPMLFeed {
        OPMLDocument.OPMLFeed(title: name, feedURL: "https://\(name).example/feed.xml")
    }

    private func makePodcast(_ ctx: ModelContext, _ title: String) -> Podcast {
        let podcast = Podcast(feedURL: "https://\(title).example/feed.xml", title: title)
        ctx.insert(podcast)
        return podcast
    }

    /// The folder→feed-URLs map a re-import reconstructs from an exported document,
    /// keyed by folder name (nil = the unfiled top-level group).
    private func reimport(_ opml: String) -> [String?: [String]] {
        var map: [String?: [String]] = [:]
        for group in OPMLDocument.groups(from: opml) {
            map[group.folder] = group.feedURLs
        }
        return map
    }

    // MARK: Pure export round-trip

    func testFlatUnfiledFeedsLandAtTopLevel() {
        let opml = OPMLDocument.export(folders: [], unfiled: [feed("A"), feed("B")])
        let map = reimport(opml)
        XCTAssertEqual(map[nil], ["https://A.example/feed.xml", "https://B.example/feed.xml"])
        // No folder groups when there are no folders.
        XCTAssertEqual(map.keys.compactMap { $0 }, [])
    }

    func testSingleFolderRoundTrips() {
        let news = OPMLDocument.OPMLFolderNode(name: "News", feeds: [feed("A"), feed("B")], children: [])
        let opml = OPMLDocument.export(folders: [news], unfiled: [feed("C")])
        let map = reimport(opml)
        XCTAssertEqual(map["News"], ["https://A.example/feed.xml", "https://B.example/feed.xml"])
        XCTAssertEqual(map[nil], ["https://C.example/feed.xml"])
    }

    func testNestedSubfolderFeedsMapToTheirDirectFolder() {
        // News ▸ (A) with subfolder Tech ▸ (B); Tech nested one level deeper.
        let tech = OPMLDocument.OPMLFolderNode(name: "Tech", feeds: [feed("B")], children: [])
        let news = OPMLDocument.OPMLFolderNode(name: "News", feeds: [feed("A")], children: [tech])
        let opml = OPMLDocument.export(folders: [news], unfiled: [])
        let map = reimport(opml)
        // Each feed re-imports under the folder it is filed DIRECTLY in.
        XCTAssertEqual(map["News"], ["https://A.example/feed.xml"])
        XCTAssertEqual(map["Tech"], ["https://B.example/feed.xml"])
    }

    func testDeeplyNestedThreeLevelsRoundTrips() {
        let c = OPMLDocument.OPMLFolderNode(name: "C", feeds: [feed("cc")], children: [])
        let b = OPMLDocument.OPMLFolderNode(name: "B", feeds: [feed("bb")], children: [c])
        let a = OPMLDocument.OPMLFolderNode(name: "A", feeds: [feed("aa")], children: [b])
        let map = reimport(OPMLDocument.export(folders: [a], unfiled: []))
        XCTAssertEqual(map["A"], ["https://aa.example/feed.xml"])
        XCTAssertEqual(map["B"], ["https://bb.example/feed.xml"])
        XCTAssertEqual(map["C"], ["https://cc.example/feed.xml"])
    }

    func testEmptyFolderEmitsValidGroupThatDropsOnReimport() {
        let empty = OPMLDocument.OPMLFolderNode(name: "Empty", feeds: [], children: [])
        let filled = OPMLDocument.OPMLFolderNode(name: "News", feeds: [feed("A")], children: [])
        let opml = OPMLDocument.export(folders: [empty, filled], unfiled: [])
        // The document is still well-formed XML.
        XCTAssertNotNil(XMLParser(data: Data(opml.utf8)).parse() ? opml : nil)
        let map = reimport(opml)
        // A folder with no feeds surfaces no group on re-import.
        XCTAssertNil(map["Empty"])
        XCTAssertEqual(map["News"], ["https://A.example/feed.xml"])
    }

    func testTitlesAndURLsWithSpecialCharactersRoundTrip() {
        let feed = OPMLDocument.OPMLFeed(
            title: "Ampersands & <Angles>",
            feedURL: "https://x.example/feed?a=1&b=2"
        )
        let folder = OPMLDocument.OPMLFolderNode(name: "R & D", feeds: [feed], children: [])
        let opml = OPMLDocument.export(folders: [folder], unfiled: [])
        // Well-formed despite the raw ampersands/angles in the inputs.
        XCTAssertTrue(XMLParser(data: Data(opml.utf8)).parse())
        // The feed URL survives escaping/unescaping losslessly.
        XCTAssertEqual(OPMLDocument.feedURLs(from: opml), ["https://x.example/feed?a=1&b=2"])
        XCTAssertEqual(reimport(opml)["R & D"], ["https://x.example/feed?a=1&b=2"])
    }

    // MARK: Repository-backed export

    func testRepositoryExportPreservesHierarchyAndUnfiled() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)

        let news = repo.createSubfolder(named: "News", under: nil)
        let tech = repo.createSubfolder(named: "Tech", under: news)
        let a = makePodcast(ctx, "A")
        let b = makePodcast(ctx, "B")
        let unfiled = makePodcast(ctx, "Zed")
        repo.add(a, to: news)
        repo.add(b, to: tech)

        let map = reimport(repo.opmlExportString())

        XCTAssertEqual(map["News"], [a.feedURL])
        XCTAssertEqual(map["Tech"], [b.feedURL])
        XCTAssertEqual(map[nil], [unfiled.feedURL])
    }

    func testRepositoryExportOmitsEmptyFolderOnReimport() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        repo.createSubfolder(named: "Empty", under: nil)
        let filled = repo.createSubfolder(named: "Filled", under: nil)
        let a = makePodcast(ctx, "A")
        repo.add(a, to: filled)

        let opml = repo.opmlExportString()
        XCTAssertTrue(XMLParser(data: Data(opml.utf8)).parse(), "export must be well-formed XML")
        let map = reimport(opml)
        XCTAssertNil(map["Empty"])
        XCTAssertEqual(map["Filled"], [a.feedURL])
    }

    func testRepositoryExportWithNoFoldersIsFlatUnfiledList() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = makePodcast(ctx, "A")
        let b = makePodcast(ctx, "B")

        let map = reimport(repo.opmlExportString())
        XCTAssertEqual(map[nil]?.sorted(), [a.feedURL, b.feedURL].sorted())
        XCTAssertEqual(map.keys.compactMap { $0 }, [])
    }

    // MARK: Subscribe-to-folder offer (decision F8)

    func testOfferSuppressedWhenNoFolders() {
        XCTAssertFalse(FolderLogic.shouldOfferSubscribeToFolder(existingFolderCount: 0))
    }

    func testOfferShownWhenFoldersExist() {
        XCTAssertTrue(FolderLogic.shouldOfferSubscribeToFolder(existingFolderCount: 1))
        XCTAssertTrue(FolderLogic.shouldOfferSubscribeToFolder(existingFolderCount: 5))
    }

    func testOfferTracksRepositoryFolderCount() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        XCTAssertFalse(FolderLogic.shouldOfferSubscribeToFolder(existingFolderCount: repo.folders().count))
        repo.createFolder(name: "News")
        XCTAssertTrue(FolderLogic.shouldOfferSubscribeToFolder(existingFolderCount: repo.folders().count))
    }
}
