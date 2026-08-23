import Foundation

/// Immutable settings consumed by the real-time gain stage. The render callback
/// never reads SwiftData or allocates; a new tap is created when settings change.
struct AudioGainLimiterConfiguration: Equatable, Sendable {
    static let disabled = AudioGainLimiterConfiguration(gain: 1)

    let gain: Float
    let kneeStart: Float

    init(gain: Float, kneeStart: Float = 0.9) {
        self.gain = min(max(gain, 1), 3)
        self.kneeStart = min(max(kneeStart, 0.5), 0.99)
    }

    var isEnabled: Bool { gain > 1 }
}

/// Allocation-free Float32 PCM processing suitable for an audio render callback.
/// The smooth knee is identity below `kneeStart`, continuous at the boundary,
/// and asymptotically bounded below full scale so boosted samples never clip.
enum AudioGainLimiter {
    static func process(
        _ samples: UnsafeMutablePointer<Float>,
        count: Int,
        configuration: AudioGainLimiterConfiguration
    ) {
        guard count > 0, configuration.isEnabled else { return }
        let knee = configuration.kneeStart
        let headroom = 1 - knee

        for index in 0..<count {
            let amplified = samples[index] * configuration.gain
            let magnitude = abs(amplified)
            guard magnitude > knee else {
                samples[index] = amplified
                continue
            }

            let normalizedOvershoot = (magnitude - knee) / headroom
            let limitedMagnitude = knee + headroom * (1 - exp(-normalizedOvershoot))
            samples[index] = amplified.sign == .minus ? -limitedMagnitude : limitedMagnitude
        }
    }
}

struct SilenceDetectionConfiguration: Equatable, Sendable {
    let thresholdDecibels: Float
    let minimumDurationSeconds: Double

    init(thresholdDecibels: Float = -42, minimumDurationSeconds: Double = 0.35) {
        self.thresholdDecibels = min(max(thresholdDecibels, -80), -12)
        self.minimumDurationSeconds = min(max(minimumDurationSeconds, 0.1), 2)
    }

    var linearThreshold: Float { pow(10, thresholdDecibels / 20) }

    func minimumFrameCount(sampleRate: Double) -> Int {
        max(1, Int((minimumDurationSeconds * sampleRate).rounded(.up)))
    }
}

/// Stateful, allocation-free decision logic for the real-time audio callback.
/// Earshot preserves the beginning of every quiet span, then reduces the
/// remainder to one frame per callback. Keeping one frame avoids presenting a
/// zero-frame buffer, which media pipelines may interpret as end-of-stream.
struct SilenceCompactionState: Sendable {
    private(set) var consecutiveSilentFrames: Int64 = 0

    mutating func reset() {
        consecutiveSilentFrames = 0
    }

    mutating func framesToKeep(
        sourceFrames: Int,
        rootMeanSquare: Float,
        sampleRate: Double,
        configuration: SilenceDetectionConfiguration
    ) -> Int {
        guard sourceFrames > 0 else { return 0 }
        guard SilenceDetectionLogic.isSilent(
            rootMeanSquare: rootMeanSquare,
            configuration: configuration
        ) else {
            consecutiveSilentFrames = 0
            return sourceFrames
        }

        let minimumFrames = Int64(configuration.minimumFrameCount(sampleRate: sampleRate))
        let previousFrames = consecutiveSilentFrames
        consecutiveSilentFrames = min(
            Int64.max - Int64(sourceFrames),
            previousFrames
        ) + Int64(sourceFrames)

        guard previousFrames < minimumFrames else { return 1 }
        let framesBeforeThreshold = minimumFrames - previousFrames
        return min(sourceFrames, max(1, Int(framesBeforeThreshold)))
    }
}

/// Pure silence classification used by the future timeline-compression stage.
/// This deliberately does not claim time saved: accounting must use frames the
/// shipping processor actually removes, never merely detected quiet frames.
enum SilenceDetectionLogic {
    static func rootMeanSquare(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sumOfSquares: Double = 0
        for index in 0..<count {
            let sample = Double(samples[index])
            sumOfSquares += sample * sample
        }
        return Float(sqrt(sumOfSquares / Double(count)))
    }

    static func isSilent(
        rootMeanSquare: Float,
        configuration: SilenceDetectionConfiguration
    ) -> Bool {
        rootMeanSquare <= configuration.linearThreshold
    }

    static func savedSeconds(sourceFrames: Int64, outputFrames: Int64, sampleRate: Double) -> Double {
        guard sourceFrames > outputFrames, outputFrames >= 0, sampleRate > 0 else { return 0 }
        return Double(sourceFrames - outputFrames) / sampleRate
    }
}
