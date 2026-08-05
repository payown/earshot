import SwiftData
import XCTest
@testable import Earshot

/// Guards the #781 root-container seam without changing production launch yet.
/// A data-bound root is created only from `.ready`; unavailable and recovery
/// carry no fallback container, and process-lifetime services claim one final
/// container exactly once.
@MainActor
final class AppRuntimeTests: XCTestCase {
    func testUnavailableRuntimeCanInstallReadyContainer() throws {
        let runtime = AppRuntime(mode: .testHost)
        XCTAssertNil(runtime.readyContainer)
        guard case .unavailable = runtime.phase else {
            return XCTFail("runtime must begin without a store")
        }

        let container = try ModelContainerFactory.makeInMemory()
        runtime.install(.ready(container))

        XCTAssertTrue(runtime.readyContainer === container)
        guard case let .ready(installed, generation) = runtime.phase else {
            return XCTFail("ready load must publish the real container")
        }
        XCTAssertTrue(installed === container)
        XCTAssertEqual(generation, 1)
    }

    func testRecoveryCarriesNoContainer() {
        let runtime = AppRuntime(
            load: .recovery(.corruptStore), mode: .testHost
        )

        XCTAssertNil(runtime.readyContainer)
        guard case .recovery(let state) = runtime.phase else {
            return XCTFail("recovery must not publish a fallback container")
        }
        XCTAssertEqual(state, .corruptStore)
    }

    func testRootServicesClaimSameContainerOnlyOnce() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let runtime = AppRuntime(load: .ready(container), mode: .testHost)

        XCTAssertTrue(runtime.claimRootServiceActivation(for: container))
        XCTAssertFalse(runtime.claimRootServiceActivation(for: container))
    }

    func testIncomingFileWaitsUntilRootConsumesIt() {
        let runtime = AppRuntime(mode: .testHost)
        let opml = URL(fileURLWithPath: "/tmp/subscriptions.opml")

        runtime.enqueueIncomingFile(URL(string: "https://example.com/list.opml")!)
        XCTAssertNil(runtime.pendingIncomingFileURL)

        runtime.enqueueIncomingFile(opml)
        XCTAssertEqual(runtime.pendingIncomingFileURL, opml)
        XCTAssertEqual(runtime.takePendingIncomingFile(), opml)
        XCTAssertNil(runtime.pendingIncomingFileURL)
    }
}
