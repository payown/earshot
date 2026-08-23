import AVFoundation
import MediaToolbox
import Synchronization

enum AudioProcessingTapError: Error, Equatable {
    case creationFailed(OSStatus)
    case noAudioTrack
}

struct AudioProcessingConfiguration: Equatable, Sendable {
    let gainLimiter: AudioGainLimiterConfiguration
    let silenceTrimming: SilenceDetectionConfiguration?

    init(
        gainLimiter: AudioGainLimiterConfiguration = .disabled,
        silenceTrimming: SilenceDetectionConfiguration? = nil
    ) {
        self.gainLimiter = gainLimiter
        self.silenceTrimming = silenceTrimming
    }
}

/// Lock-free bridge from the real-time render callback to PlayerService. The
/// callback records only integer frame counts; conversion to seconds happens
/// later on the main actor and never blocks audio rendering.
final class AudioProcessingMetrics: @unchecked Sendable {
    private let discardedFrames = Atomic<Int64>(0)
    private let sampleRateBits = Atomic<UInt64>(0)

    func prepare(sampleRate: Double) {
        sampleRateBits.store(sampleRate.bitPattern, ordering: .relaxed)
    }

    func recordDiscardedFrames(_ count: Int) {
        guard count > 0 else { return }
        discardedFrames.wrappingAdd(Int64(count), ordering: .relaxed)
    }

    func consumeDiscardedSeconds() -> Double {
        let frames = discardedFrames.exchange(0, ordering: .acquiringAndReleasing)
        let sampleRate = Double(bitPattern: sampleRateBits.load(ordering: .acquiring))
        guard frames > 0, sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate
    }
}

/// Owns the immutable configuration and the format reported by MediaToolbox.
/// Prepare/process/unprepare are serialized by the audio machinery.
private final class AudioProcessingTapStorage {
    let configuration: AudioProcessingConfiguration
    let metrics: AudioProcessingMetrics?
    var processesFloat32 = false
    var sampleRate = 0.0
    var silenceState = SilenceCompactionState()

    init(
        configuration: AudioProcessingConfiguration,
        metrics: AudioProcessingMetrics?
    ) {
        self.configuration = configuration
        self.metrics = metrics
    }
}

enum AudioProcessingTapFactory {
    /// Creates a real MediaToolbox tap but does not attach it to live playback.
    /// Unsupported PCM formats pass through untouched; production activation
    /// requires an AudioConverter allocated during `prepare`, never in `process`.
    static func makeGainTap(
        configuration: AudioGainLimiterConfiguration
    ) throws -> MTAudioProcessingTap {
        try makeTap(
            configuration: AudioProcessingConfiguration(gainLimiter: configuration)
        )
    }

    static func makeTap(
        configuration: AudioProcessingConfiguration,
        metrics: AudioProcessingMetrics? = nil
    ) throws -> MTAudioProcessingTap {
        let initialStorage = AudioProcessingTapStorage(
            configuration: configuration,
            metrics: metrics
        )
        let retainedStorage = Unmanaged.passRetained(initialStorage)

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedStorage.toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<AudioProcessingTapStorage>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .release()
            },
            prepare: { tap, _, format in
                let state = tapStorage(for: tap)
                let flags = format.pointee.mFormatFlags
                state.processesFloat32 = format.pointee.mFormatID == kAudioFormatLinearPCM
                    && flags & kAudioFormatFlagIsFloat != 0
                    && format.pointee.mBitsPerChannel == 32
                state.sampleRate = format.pointee.mSampleRate
                state.silenceState.reset()
                state.metrics?.prepare(sampleRate: state.sampleRate)
            },
            unprepare: { tap in
                let state = tapStorage(for: tap)
                state.processesFloat32 = false
                state.sampleRate = 0
                state.silenceState.reset()
            },
            process: { tap, requestedFrames, _, bufferList, framesOut, flagsOut in
                var sourceFlags: MTAudioProcessingTapFlags = 0
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    requestedFrames,
                    bufferList,
                    &sourceFlags,
                    nil,
                    framesOut
                )
                flagsOut.pointee = sourceFlags
                guard status == noErr, tapStorage(for: tap).processesFloat32 else { return }

                let state = tapStorage(for: tap)
                let sourceFrameCount = Int(framesOut.pointee)
                guard sourceFrameCount > 0 else { return }

                var keptFrameCount = sourceFrameCount
                if let silenceConfiguration = state.configuration.silenceTrimming {
                    var sumOfSquares = 0.0
                    var sampleCount = 0
                    for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                        guard let data = buffer.mData else { continue }
                        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        let samples = data.assumingMemoryBound(to: Float.self)
                        for index in 0..<count {
                            let sample = Double(samples[index])
                            sumOfSquares += sample * sample
                        }
                        sampleCount += count
                    }
                    let rootMeanSquare = sampleCount > 0
                        ? Float(sqrt(sumOfSquares / Double(sampleCount)))
                        : 0
                    keptFrameCount = state.silenceState.framesToKeep(
                        sourceFrames: sourceFrameCount,
                        rootMeanSquare: rootMeanSquare,
                        sampleRate: state.sampleRate,
                        configuration: silenceConfiguration
                    )
                    state.metrics?.recordDiscardedFrames(sourceFrameCount - keptFrameCount)
                    if keptFrameCount < sourceFrameCount {
                        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                        for index in buffers.indices {
                            let bytesPerFrame = Int(buffers[index].mDataByteSize)
                                / sourceFrameCount
                            buffers[index].mDataByteSize = UInt32(bytesPerFrame * keptFrameCount)
                        }
                        framesOut.pointee = CMItemCount(keptFrameCount)
                    }
                } else {
                    state.silenceState.reset()
                }

                let configuration = state.configuration.gainLimiter
                for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                    guard let data = buffer.mData else { continue }
                    let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    AudioGainLimiter.process(
                        data.assumingMemoryBound(to: Float.self),
                        count: sampleCount,
                        configuration: configuration
                    )
                }
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tap
        )
        guard status == noErr, let tap else {
            retainedStorage.release()
            throw AudioProcessingTapError.creationFailed(status)
        }
        return tap
    }

    /// Builds the file-based AVPlayer audio mix needed to attach the gain tap.
    /// Apple documents that AVPlayerItem.audioMix is unsupported for HLS, so the
    /// caller must retain the baseline path for HLS and other unsupported media.
    @MainActor
    static func makeFileAudioMix(
        asset: AVAsset,
        configuration: AudioGainLimiterConfiguration
    ) async throws -> AVAudioMix {
        try await makeFileAudioMix(
            asset: asset,
            configuration: AudioProcessingConfiguration(gainLimiter: configuration)
        )
    }

    @MainActor
    static func makeFileAudioMix(
        asset: AVAsset,
        configuration: AudioProcessingConfiguration,
        metrics: AudioProcessingMetrics? = nil
    ) async throws -> AVAudioMix {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioProcessingTapError.noAudioTrack
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = try makeTap(
            configuration: configuration,
            metrics: metrics
        )
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}

private func tapStorage(for tap: MTAudioProcessingTap) -> AudioProcessingTapStorage {
    Unmanaged<AudioProcessingTapStorage>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
}
