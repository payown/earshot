import Foundation
#if canImport(MediaIntents)
import AppIntents
#endif

/// A single queue orders donations with opt-out and deletion. No playback task
/// waits for this work; cleanup does wait so old writes cannot restore content.
@MainActor
final class ListeningDonations {
    private static let identifiersKey = "earshot.systemSearch.donatedEpisodeIDs"
    static let shared = ListeningDonations(
        persistedIDs: Set(UserDefaults.standard.stringArray(forKey: identifiersKey) ?? []),
        saveIDs: { UserDefaults.standard.set($0.sorted(), forKey: identifiersKey) }
    )
    static let enabledKey = "earshot.systemSearch.listeningEnabled"
    static var isEnabled: Bool {
        LibrarySearchIndex.isEnabled && UserDefaults.standard.bool(forKey: enabledKey)
    }
    private var allowed: [String: SearchContent] = [:]
    private var tail: Task<Void, Error>?
    private var donatedIDs: Set<String>
    private let saveIDs: (Set<String>) -> Void
    private let writer: any ListeningDonationWriting
    private let enabled: () -> Bool

    init(writer: any ListeningDonationWriting = SystemListeningDonationWriter(),
         enabled: @escaping () -> Bool = { ListeningDonations.isEnabled },
         persistedIDs: Set<String> = [], saveIDs: @escaping (Set<String>) -> Void = { _ in }) {
        self.writer = writer
        self.enabled = enabled
        self.donatedIDs = persistedIDs
        self.saveIDs = saveIDs
    }

    func recordPlayback(id: String) {
        guard enabled(), allowed[id] != nil else { return }
        let task = enqueue { [self] in
            guard enabled(), let record = allowed[id] else { return }
            try await writer.remove(id: id)
            donatedIDs.remove(id)
            saveIDs(donatedIDs)
            guard enabled(), allowed[id] != nil else { return }
            // Persist before submission so a process exit after the system accepts
            // it cannot leave an untracked donation behind.
            donatedIDs.insert(id)
            saveIDs(donatedIDs)
            try await writer.donate(record)
        }
        Task {
            do { try await task.value }
            catch { AppLog.data.error("Could not donate a listening action") }
        }
    }

    func reconcile(_ records: [SearchContent]) async throws {
        guard enabled() else { try await clear(); return }
        let next = Dictionary(uniqueKeysWithValues: records.filter { $0.guid != nil }.map { ($0.id, $0) })
        allowed = next
        let task = enqueue { [self] in
            for id in donatedIDs.filter({ allowed[$0] == nil }) {
                try await writer.remove(id: id)
                donatedIDs.remove(id)
                saveIDs(donatedIDs)
            }
        }
        try await task.value
    }

    func clear() async throws {
        allowed = [:]
        let task = enqueue { [self] in
            try await writer.removeAll()
            donatedIDs = []
            saveIDs(donatedIDs)
        }
        try await task.value
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
        let previous = tail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try await operation()
        }
        tail = task
        return task
    }
}

@MainActor
protocol ListeningDonationWriting {
    func donate(_ record: SearchContent) async throws
    func remove(id: String) async throws
    func removeAll() async throws
}

@MainActor
private struct SystemListeningDonationWriter: ListeningDonationWriting {
    func donate(_ record: SearchContent) async throws {
        #if canImport(MediaIntents)
        if #available(iOS 27.0, *) {
            var intent = PlayPodcastAudioIntent()
            intent.audioEntity = .episode(SiriPodcastEpisode(record))
            _ = try await IntentDonationManager.shared.donate(intent: intent)
        }
        #endif
    }
    func remove(id: String) async throws {
        #if canImport(MediaIntents)
        if #available(iOS 27.0, *) {
            _ = try await IntentDonationManager.shared.deleteDonations(matching:
                .intentType(PlayPodcastAudioIntent.self, entityIdentifier: EntityIdentifier(for: SiriPodcastEpisode.self, identifier: id)))
        }
        #endif
    }
    func removeAll() async throws {
        #if canImport(MediaIntents)
        if #available(iOS 27.0, *) {
            _ = try await IntentDonationManager.shared.deleteDonations(matching: .intentType(PlayPodcastAudioIntent.self))
        }
        #endif
    }
}
