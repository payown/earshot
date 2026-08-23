import AVFoundation

/// Playback-wide audio choices that are independent of optional processing.
enum PlaybackAudioLogic {
    /// `.spectral` reintroduced tester-reported watery or metallic voices at
    /// common podcast speeds when it was restored provisionally in #697.
    static let timePitchAlgorithm: AVAudioTimePitchAlgorithm = .timeDomain
}
