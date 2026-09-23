/// Unknown counts remain visible while the background snapshot is loading or
/// retrying. Filtering never mutates subscription, episode, or playback state.
enum LibraryPodcastFilter {
    static func includes(unplayedCount: Int?, hideCaughtUp: Bool) -> Bool {
        !hideCaughtUp || unplayedCount != 0
    }

    static func replacementFocus<ID: Hashable>(
        removed: ID, previous: [ID], remaining: [ID]
    ) -> ID? {
        guard let index = previous.firstIndex(of: removed) else { return remaining.first }
        let survivors = Set(remaining)
        return previous.dropFirst(index + 1).first(where: survivors.contains)
            ?? previous.prefix(index).reversed().first(where: survivors.contains)
            ?? remaining.first
    }
}
