import AVFoundation

/// Injectable boundary around the audio-session calls PlayerService owns.
/// Keeping the system object behind this narrow protocol makes routing
/// configuration testable without activating simulator audio.
@MainActor
protocol PlayerAudioSession: AnyObject {
    var notificationObject: AnyObject { get }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func activate() throws
    func setPreferredOutputNumberOfChannels(_ count: Int) throws
}

extension AVAudioSession: PlayerAudioSession {
    var notificationObject: AnyObject { self }

    func activate() throws {
        try setActive(true)
    }
}
