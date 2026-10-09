import Foundation

/// Immutable settings consumed by the real-time gain stage. The render callback
/// never reads SwiftData or allocates; a new tap is created when settings change.
struct AudioGainLimiterConfiguration: Equatable, Sendable {
    static let disabled = AudioGainLimiterConfiguration(gain: 1)

    let gain: Float
    let kneeStart: Float
    let limitsUnityGain: Bool

    init(gain: Float, kneeStart: Float = 0.9, limitsUnityGain: Bool = false) {
        self.gain = min(max(gain, 1), 3)
        self.kneeStart = min(max(kneeStart, 0.5), 0.99)
        self.limitsUnityGain = limitsUnityGain
    }

    var isEnabled: Bool { gain > 1 || limitsUnityGain }
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

        for index in 0..<count {
            samples[index] = limit(samples[index], gain: configuration.gain, knee: knee)
        }
    }

    /// The same output ceiling is used after EQ and compression, where unity
    /// input gain can still produce a sample above full scale.
    static func limit(_ sample: Float, gain: Float, knee: Float) -> Float {
        let amplified = sample * gain
        let magnitude = abs(amplified)
        guard magnitude > knee else { return amplified }
        let headroom = 1 - knee
        let limited = knee + headroom * (1 - exp(-(magnitude - knee) / headroom))
        // At high input levels Float rounding can turn the asymptote into
        // exactly 1.0. Keep the PCM output strictly inside full scale.
        let bounded = min(limited, Float(1).nextDown)
        return amplified.sign == .minus ? -bounded : bounded
    }
}

/// Device-local compression strength. Unlike volume boost, this follows the
/// signal envelope and reduces the level of loud passages relative to quiet
/// ones. The fixed attack/release values keep the choice understandable.
enum DynamicRangeCompressionLevel: String, CaseIterable, Identifiable, Sendable {
    case off, light, balanced, strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .balanced: "Balanced"
        case .strong: "Strong"
        }
    }

    var configuration: AudioCompressorConfiguration {
        switch self {
        case .off: .disabled
        case .light: .init(thresholdDecibels: -24, ratio: 2, makeupDecibels: 2)
        case .balanced: .init(thresholdDecibels: -30, ratio: 3, makeupDecibels: 4)
        case .strong: .init(thresholdDecibels: -36, ratio: 4, makeupDecibels: 6)
        }
    }
}

enum EqualizerBandGain: Int, CaseIterable, Identifiable, Sendable {
    case cut6 = -6, cut3 = -3, neutral = 0, boost3 = 3, boost6 = 6

    var id: Int { rawValue }
    var title: String { rawValue > 0 ? "+\(rawValue) dB" : "\(rawValue) dB" }
    var spokenValue: String {
        switch self {
        case .cut6: "minus 6 decibels"
        case .cut3: "minus 3 decibels"
        case .neutral: "neutral"
        case .boost3: "plus 3 decibels"
        case .boost6: "plus 6 decibels"
        }
    }
}

struct AudioCompressorConfiguration: Equatable, Sendable {
    static let disabled = AudioCompressorConfiguration(
        thresholdDecibels: 0, ratio: 1, makeupDecibels: 0
    )

    let thresholdDecibels: Float
    let ratio: Float
    let makeupDecibels: Float
    let attackSeconds: Float
    let releaseSeconds: Float

    init(
        thresholdDecibels: Float,
        ratio: Float,
        makeupDecibels: Float,
        attackSeconds: Float = 0.01,
        releaseSeconds: Float = 0.25
    ) {
        self.thresholdDecibels = min(max(thresholdDecibels, -48), 0)
        self.ratio = min(max(ratio, 1), 8)
        self.makeupDecibels = min(max(makeupDecibels, 0), 9)
        self.attackSeconds = min(max(attackSeconds, 0.001), 0.1)
        self.releaseSeconds = min(max(releaseSeconds, 0.05), 1)
    }

    var isEnabled: Bool { ratio > 1 }
}

struct AudioEqualizerConfiguration: Equatable, Sendable {
    static let disabled = AudioEqualizerConfiguration(
        enabled: false, bassDecibels: 0, speechDecibels: 0, trebleDecibels: 0
    )

    let enabled: Bool
    let bassDecibels: Float
    let speechDecibels: Float
    let trebleDecibels: Float

    init(enabled: Bool, bassDecibels: Float, speechDecibels: Float, trebleDecibels: Float) {
        self.enabled = enabled
        self.bassDecibels = min(max(bassDecibels, -6), 6)
        self.speechDecibels = min(max(speechDecibels, -6), 6)
        self.trebleDecibels = min(max(trebleDecibels, -6), 6)
    }

    var isActive: Bool {
        enabled && (bassDecibels != 0 || speechDecibels != 0 || trebleDecibels != 0)
    }
}

/// Prepared off the render thread. One envelope controls every channel, so a
/// loud event on one side cannot move the stereo image. The gain lookup avoids
/// log/pow work in the callback; only table indexing and interpolation remain.
struct AudioCompressorState {
    private static let tableSize = 8_192
    private static let maximumLevel: Float = 4

    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    private let gainTable: [Float]
    private var envelope: Float = 0

    init(configuration: AudioCompressorConfiguration, sampleRate: Double) {
        let rate = max(sampleRate, 8_000)
        attackCoefficient = Float(exp(-1 / (Double(configuration.attackSeconds) * rate)))
        releaseCoefficient = Float(exp(-1 / (Double(configuration.releaseSeconds) * rate)))
        let threshold = pow(10, configuration.thresholdDecibels / 20)
        let exponent = 1 - 1 / configuration.ratio
        let makeup = pow(10, configuration.makeupDecibels / 20)
        gainTable = (0...Self.tableSize).map { index in
            let level = Self.maximumLevel * Float(index) / Float(Self.tableSize)
            guard level > threshold else { return makeup }
            return pow(threshold / level, exponent) * makeup
        }
    }

    mutating func reset() { envelope = 0 }

    mutating func gain(for peak: Float) -> Float {
        let level = min(max(peak.isFinite ? peak : 0, 0), Self.maximumLevel)
        let coefficient = level > envelope ? attackCoefficient : releaseCoefficient
        envelope = coefficient * envelope + (1 - coefficient) * level
        if envelope < 0.000_001 { envelope = 0 }
        let position = envelope * Float(Self.tableSize) / Self.maximumLevel
        let lower = min(Int(position), Self.tableSize - 1)
        let fraction = position - Float(lower)
        return gainTable[lower] + (gainTable[lower + 1] - gainTable[lower]) * fraction
    }
}

/// A complementary three-band crossover. At 0 dB for all bands, the bands
/// sum back to the input. State is independent for each channel.
struct AudioEqualizerState {
    private let lowCoefficient: Float
    private let highCoefficient: Float
    private let bassGain: Float
    private let speechGain: Float
    private let trebleGain: Float
    private var lowPass: Float = 0
    private var highPass: Float = 0

    init(configuration: AudioEqualizerConfiguration, sampleRate: Double) {
        let rate = max(sampleRate, 8_000)
        lowCoefficient = Float(1 - exp(-2 * Double.pi * 250 / rate))
        highCoefficient = Float(1 - exp(-2 * Double.pi * 4_000 / rate))
        bassGain = pow(10, configuration.bassDecibels / 20)
        speechGain = pow(10, configuration.speechDecibels / 20)
        trebleGain = pow(10, configuration.trebleDecibels / 20)
    }

    mutating func reset() { lowPass = 0; highPass = 0 }

    mutating func process(_ input: Float) -> Float {
        let sample = input.isFinite ? input : 0
        lowPass += lowCoefficient * (sample - lowPass)
        highPass += highCoefficient * (sample - highPass)
        return lowPass * bassGain
            + (highPass - lowPass) * speechGain
            + (sample - highPass) * trebleGain
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
