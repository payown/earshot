import AVFoundation

/// Pure mapping from the "voice enhance" setting to the audio-session values that
/// realize it. Kept separate from ``PlayerService`` so the decision is unit-tested
/// without touching a live `AVAudioSession`.
///
/// Voice enhance on  => spoken-audio mode (system voice-clarity processing) + mono.
/// Voice enhance off => default mode + stereo (the baseline for new installs).
enum AudioEnhancementLogic {
    static func mode(voiceEnhanceEnabled: Bool) -> AVAudioSession.Mode {
        voiceEnhanceEnabled ? .spokenAudio : .default
    }

    /// Preferred output channel count. This is a hint — some Bluetooth routes
    /// ignore it, which is expected, not a bug.
    static func outputChannels(voiceEnhanceEnabled: Bool) -> Int {
        voiceEnhanceEnabled ? 1 : 2
    }
}
