import XCTest
import SwiftUI
import Observation
@testable import Earshot

@MainActor
final class DeferredTabContentTests: XCTestCase {
    @Observable final class Selection {
        var selected = false
    }
    private final class Counter {
        var constructions = 0
        var appearances = 0
    }
    private struct Probe: View {
        let counter: Counter
        init(counter: Counter) {
            self.counter = counter
            counter.constructions += 1
        }
        var body: some View {
            Text("Loaded tab").onAppear { counter.appearances += 1 }
        }
    }
    private struct Host: View {
        let selection: Selection
        let counter: Counter
        var body: some View {
            DeferredTabContent(isSelected: selection.selected) {
                Probe(counter: counter)
            }
        }
    }

    func testUnopenedTabDoesNotConstructDataViewAndSelectionRetainsIt() async {
        let selection = Selection()
        let counter = Counter()
        let controller = UIHostingController(rootView: Host(selection: selection, counter: counter))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(counter.constructions, 0)
        selection.selected = true
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(counter.constructions, 0)
        XCTAssertEqual(counter.appearances, 1)
        selection.selected = false
        try? await Task.sleep(for: .milliseconds(100))
        selection.selected = true
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(counter.appearances, 1, "Revisiting must preserve the mounted tab's identity")
    }
}
