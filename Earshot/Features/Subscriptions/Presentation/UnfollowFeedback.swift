import SwiftData
import SwiftUI

/// Screen-local presentation for a confirmed Unfollow. The repository owns the
/// cross-screen mutation guard; this state only makes its wait and result clear.
@MainActor
struct UnfollowFeedbackState {
    private(set) var pendingID: PersistentIdentifier?
    private(set) var title = ""
    var showsFailure = false

    var isPending: Bool { pendingID != nil }

    mutating func begin(_ podcast: Podcast) -> Bool {
        let id = podcast.persistentModelID
        guard pendingID == nil, !SubscriptionRepository.isUnfollowing(id) else {
            Announcer.announce("Unfollow already in progress")
            return false
        }
        pendingID = id
        title = podcast.displayName
        showsFailure = false
        Announcer.announce("Unfollowing \(title)")
        return true
    }

    mutating func finish(succeeded: Bool) {
        pendingID = nil
        showsFailure = !succeeded
    }

    /// Lets UI automation observe the otherwise brief progress state after its
    /// synchronous tap waits for idle. Never present in a release build.
    static func holdForUITestIfRequested() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestHoldUnfollowFeedback") {
            try? await Task.sleep(for: .seconds(4))
        }
#endif
    }
}

private struct UnfollowFeedbackModifier: ViewModifier {
    @Binding var feedback: UnfollowFeedbackState

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                if feedback.isPending {
                    ProgressView("Unfollowing \(feedback.title)")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.regularMaterial)
                }
            }
            .alert("Couldn't unfollow podcast", isPresented: $feedback.showsFailure) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The podcast is still in your library. Please try again.")
            }
    }
}

extension View {
    func unfollowFeedback(_ feedback: Binding<UnfollowFeedbackState>) -> some View {
        modifier(UnfollowFeedbackModifier(feedback: feedback))
    }
}
