import Foundation
import XCTest
@testable import Earshot

final class ListeningPlacesMergePlannerTests: XCTestCase {
    private let id = "episode:aaaaaaaaaaaaaaaa"

    func testNewerBackwardSeekWinsAndOlderFurtherProgressDoesNot() {
        let local = event(position: 900, time: 20, device: "phone")
        let backward = remote(position: 120, time: 30, device: "desktop")
        XCTAssertEqual(decide(.event(local), [backward]), .apply(event(position: 120, time: 30, device: "desktop")))
        let older = remote(position: 2_000, time: 10, device: "desktop")
        XCTAssertEqual(decide(.event(local), [older]), .keepLocal)
    }

    func testNewerResetWinsButOlderResetCannotClearProgress() {
        let local = event(position: 900, time: 20, device: "phone")
        let newer = remote(position: 0, time: 30, device: "desktop", reset: true)
        XCTAssertEqual(decide(.event(local), [newer]),
                       .apply(event(position: 0, time: 30, device: "desktop", reset: true)))
        let older = remote(position: 0, time: 10, device: "desktop", reset: true)
        XCTAssertEqual(decide(.event(local), [older]), .keepLocal)
    }

    func testLoadedEpisodeWaitsEvenForNewerPlaceAndReset() {
        let local = event(position: 900, time: 20, device: "phone")
        for reset in [false, true] {
            let incoming = remote(position: 100, time: 30, device: "desktop", reset: reset)
            XCTAssertEqual(decide(.event(local), [incoming], loaded: true),
                           .deferLoaded(event(position: reset ? 0 : 100, time: 30,
                                              device: "desktop", reset: reset)))
        }
    }

    func testUnknownLegacyStateIsNeverAssignedImportOrExportTime() {
        XCTAssertEqual(decide(.unknownLegacy, [remote(position: 100, time: 30, device: "desktop")]), .keepLocal)
        XCTAssertEqual(decide(.knownNoEvent, [remote(position: 100, time: 30, device: "desktop")]),
                       .apply(event(position: 100, time: 30, device: "desktop")))
    }

    func testRemoteTiesBeatLocalAndRemoteOrderIsDeterministic() {
        let local = event(position: 900, time: 20, device: "phone")
        let a = remote(position: 100, time: 20, device: "a")
        let z = remote(position: 200, time: 20, device: "z")
        let expected = ListeningPlacesMergeDecision.apply(event(position: 200, time: 20, device: "z"))
        XCTAssertEqual(decide(.event(local), [a, z]), expected)
        XCTAssertEqual(decide(.event(local), [z, a]), expected)
    }

    func testGuardedEffectiveTimeWinsInsteadOfRawFutureClock() {
        let local = event(position: 900, time: 20, device: "phone")
        let incoming = remote(position: 100, time: 10, device: "desktop", rawTime: 9_999)
        XCTAssertEqual(decide(.event(local), [incoming]), .keepLocal)
    }

    private func decide(_ local: ListeningPlacesLocalPlace, _ remotes: [ListeningPlacesRemoteEvent],
                        loaded: Bool = false) -> ListeningPlacesMergeDecision {
        ListeningPlacesMergePlanner.decide(id: id, local: local, remote: remotes, isLoaded: loaded)
    }

    private func event(position: Int, time: TimeInterval, device: String,
                       reset: Bool = false) -> ListeningPlacesStateEvent {
        ListeningPlacesStateEvent(id: id, positionMilliseconds: position, played: false,
                                  updatedAt: Date(timeIntervalSince1970: time),
                                  sourceDeviceID: device, isReset: reset)
    }

    private func remote(position: Int, time: TimeInterval, device: String,
                        reset: Bool = false, rawTime: TimeInterval? = nil) -> ListeningPlacesRemoteEvent {
        let record = ListeningPlaceRecord(id: id, kind: reset ? nil : "episode",
            positionMilliseconds: reset ? nil : position, durationMilliseconds: nil,
            played: reset ? nil : false, updatedAt: Date(timeIntervalSince1970: rawTime ?? time),
            label: nil, feed: nil, deleted: reset ? true : nil)
        return ListeningPlacesRemoteEvent(deviceID: device,
            entry: ListeningPlacesInboundEntry(record: record,
                effectiveUpdatedAt: Date(timeIntervalSince1970: time)))
    }
}
