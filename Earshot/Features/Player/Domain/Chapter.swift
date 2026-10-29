import Foundation

/// A single chapter within an episode, from a Podcasting 2.0 chapters file,
/// embedded (ID3/AVAsset) metadata, or timestamps parsed from the show notes.
struct Chapter: Equatable, Identifiable, Sendable {
    let index: Int
    /// Start offset in seconds.
    let startTime: Double
    let title: String
    let imageURL: String?

    // Keep clock formatting, Int conversion, and CMTime(seconds:timescale:)
    // representable. This permits offsets up to roughly 245,000 years.
    static let maximumStartTimeExclusive = Double(Int32.max) * 3_600

    static func isValidStartTime(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value < maximumStartTimeExclusive
    }

    var id: Int { index }

    init(index: Int, startTime: Double, title: String, imageURL: String? = nil) {
        self.index = index
        self.startTime = startTime
        self.title = title
        self.imageURL = imageURL
    }
}

extension Array where Element == Chapter {
    /// Defend the playback engine against malformed chapters from any source.
    /// Only reindex when entries are removed; valid lists retain their identities.
    func removingInvalidStartTimes() -> [Chapter] {
        guard contains(where: { !Chapter.isValidStartTime($0.startTime) }) else { return self }
        return filter { Chapter.isValidStartTime($0.startTime) }.enumerated().map { index, chapter in
            Chapter(index: index, startTime: chapter.startTime, title: chapter.title, imageURL: chapter.imageURL)
        }
    }


    /// The index of the chapter that contains `seconds` (the last chapter whose
    /// start is <= the position), or nil before the first chapter starts.
    func activeChapterIndex(at seconds: Double) -> Int? {
        var result: Int?
        for (i, chapter) in enumerated() where chapter.startTime <= seconds {
            result = i
        }
        return result
    }
}
