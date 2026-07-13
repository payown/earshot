import Foundation

/// Maps a subscribe / feed-fetch failure to a user-facing message that is safe
/// to both display and SPEAK via VoiceOver (#688).
///
/// The problem it solves: `FeedError.network`'s associated value is the raw
/// transport `localizedDescription` (e.g. "NSURLErrorDomain -1009", or text that
/// embeds the feed URL). Splatting that into an announcement or accessibility
/// label lets VoiceOver's automatic language detection trip on the token and
/// switch voices mid-utterance — the garbled announcement a tester reported.
/// The `Announcer` language-pin (see ``Announcer/announcementAttributes``) stops
/// the voice-switch, but a raw "NSURLErrorDomain -1009" is still poor UX to read
/// aloud, so we never surface it: the raw error goes to `AppLog`, the user hears
/// a curated sentence.
///
/// Pure and SwiftData-free so the wording is unit-testable.
enum SubscribeErrorMessage {
    /// A curated, VoiceOver-safe message for a subscribe/feed failure. Uses each
    /// error's own curated `errorDescription` EXCEPT `FeedError.network` (whose
    /// description is the raw transport string) and any error without a
    /// `LocalizedError` description, both of which map to a generic connection
    /// message.
    static func userFacing(_ error: Error) -> String {
        // FeedError.network carries the raw transport localizedDescription — the
        // one case whose errorDescription is NOT safe to surface. Replace it.
        if case FeedError.network = error {
            return "Couldn't reach that feed. Check your connection and try again."
        }
        if let described = (error as? LocalizedError)?.errorDescription,
           !described.isEmpty {
            return described
        }
        return "Something went wrong. Check the link and your connection, then try again."
    }
}
