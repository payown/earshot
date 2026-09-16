import SwiftUI

/// A pending external request waits for existing presentations to finish. It
/// never dismisses another flow or changes the existing VoiceOver focus rules.
struct LibrarySearchPresentation: ViewModifier {
    @Binding var episode: Episode?
    let isReady: Bool
    let route: @MainActor (SearchContent) -> Void

    private var taskID: String? {
        LibraryIntentBridge.shared.pending.map { $0.id + (isReady ? ":ready" : ":waiting") }
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $episode) { ShowNotesView(episode: $0) }
            .task(id: taskID) {
                guard isReady, let request = LibraryIntentBridge.shared.pending else { return }
                while !Task.isCancelled, LibraryIntentBridge.shared.pending == request {
                    if !LibrarySearchIndex.isEnabled { LibraryIntentBridge.shared.clear(); return }
                    if presentationIsReady {
                        route(request)
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
    }

    private var presentationIsReady: Bool {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return false }
        return root.presentedViewController == nil && episode == nil
    }
}
