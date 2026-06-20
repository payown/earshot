import Foundation

/// A single chapter within an episode, from a Podcasting 2.0 chapters file,
/// embedded (ID3/AVAsset) metadata, or timestamps parsed from the show notes.
struct Chapter: Equatable, Identifiable {
    let index: Int
    /// Start offset in seconds.
    let startTime: Double
    let title: String
    let imageURL: String?

    var id: Int { index }

    init(index: Int, startTime: Double, title: String, imageURL: String? = nil) {
        self.index = index
        self.startTime = startTime
        self.title = title
        self.imageURL = imageURL
    }
}

extension Array where Element == Chapter {
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
