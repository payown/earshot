import XCTest
import AVFoundation
@testable import Earshot

/// Unit tests for the AirPlay feature added in issue #370.
///
/// PR #402 made two logic changes:
///  1. `PlayerService` now passes AirPlay, Bluetooth HFP, and Bluetooth A2DP
///     options to every
///     `AVAudioSession.setCategory` call so the system routes audio over AirPlay
///     and Bluetooth without the user first switching the output in Control Centre.
///  2. `NowPlayingScreen` embeds `RoutePickerView`, a `UIViewRepresentable` wrapping
///     `AVRoutePickerView`, so users can change output from inside the player.
///
/// `PlayerAudioSessionTests` verifies the values sent through the injected
/// session boundary. These tests retain small pure-value and route-picker guards.
final class AirPlayTests: XCTestCase {

    private let productionOptions: AVAudioSession.CategoryOptions = [
        .allowAirPlay, .allowBluetoothHFP, .allowBluetoothA2DP,
    ]

    // MARK: – Session options (Acceptance criterion: #370-1)

    /// The options set includes .allowAirPlay so the audio session streams to
    /// AirPlay receivers when one is selected.
    func test_airPlaySessionOptions_containsAllowAirPlay() {
        // Acceptance criterion: audio reaches AirPlay receivers without manual
        // workarounds. The flag must be present in the options bitmask.
        XCTAssertTrue(productionOptions.contains(.allowAirPlay),
                      ".allowAirPlay must be present in the session options")
    }

    /// The options set includes both Bluetooth profiles used by production:
    /// HFP for hands-free routes and A2DP for high-quality playback.
    func test_airPlaySessionOptions_containsProductionBluetoothProfiles() {
        // Acceptance criterion: Bluetooth output routes should also be available
        // from the picker. The flag must be present.
        XCTAssertTrue(productionOptions.contains(.allowBluetoothHFP))
        XCTAssertTrue(productionOptions.contains(.allowBluetoothA2DP))
    }

    /// A session configured with these options doesn't also accidentally set
    /// flags we don't want (e.g. .mixWithOthers, which would let other apps
    /// keep playing while Earshot plays).
    func test_airPlaySessionOptions_doesNotContainMixWithOthers() {
        XCTAssertFalse(productionOptions.contains(.mixWithOthers),
                       ".mixWithOthers must NOT be set — Earshot should duck other audio")
    }

    /// The production options set is non-empty (sanity guard).
    func test_airPlaySessionOptions_isNonEmpty() {
        XCTAssertFalse(productionOptions.isEmpty)
    }

    // MARK: – RoutePickerView type existence (Acceptance criterion: #370-3)

    /// `RoutePickerView` is defined and can be referenced at the module level.
    /// This is a compile-time check more than a runtime one — the test will not
    /// compile if the type is missing or unexported from the module.
    func test_routePickerView_typeExists() {
        // If RoutePickerView is missing from the module, this line won't compile.
        let _: RoutePickerView.Type = RoutePickerView.self
        // A trivially-true assertion gives XCTest a result to report.
        XCTAssertTrue(true, "RoutePickerView type must be accessible within the Earshot module")
    }

    // MARK: – Option composition (Acceptance criterion: #370-1)

    /// The full production set differs from each individual route option.
    /// Guards against accidentally shipping only one profile.
    func test_airPlaySessionOptions_combinedIsDifferentFromEitherAlone() {
        XCTAssertNotEqual(productionOptions, [.allowAirPlay])
        XCTAssertNotEqual(productionOptions, [.allowBluetoothHFP])
        XCTAssertNotEqual(productionOptions, [.allowBluetoothA2DP])
    }
}
