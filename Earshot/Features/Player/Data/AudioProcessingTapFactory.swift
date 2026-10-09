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
    let compressor: AudioCompressorConfiguration
    let equalizer: AudioEqualizerConfiguration

    init(
        gainLimiter: AudioGainLimiterConfiguration = .disabled,
        silenceTrimming: SilenceDetectionConfiguration? = nil,
        compressor: AudioCompressorConfiguration = .disabled,
        equalizer: AudioEqualizerConfiguration = .disabled
    ) {
        self.gainLimiter = gainLimiter
        self.silenceTrimming = silenceTrimming
        self.compressor = compressor
        self.equalizer = equalizer
    }
}

/// Format and DSP state are prepared before audio rendering. Float32 and
/// packed signed Int16 PCM are handled without conversion buffers; other
/// formats pass through the existing unprocessed AVPlayer path.
final class AudioPCMProcessor {
    private enum SampleFormat {
        case float32, int16
    }

    private let sampleFormat: SampleFormat
    private let channelCount: Int
    private let nonInterleaved: Bool
    private let output: AudioGainLimiterConfiguration
    private let equalizerActive: Bool
    private var equalizers: [AudioEqualizerState]
    private var compressor: AudioCompressorState?

    var supportsSilenceTrimming: Bool {
        if case .float32 = sampleFormat { return true }
        return false
    }

    init?(configuration: AudioProcessingConfiguration, format: AudioStreamBasicDescription) {
        let channels = Int(format.mChannelsPerFrame)
        let flags = format.mFormatFlags
        let planar = flags & kAudioFormatFlagIsNonInterleaved != 0
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mSampleRate.isFinite, format.mSampleRate >= 8_000,
              channels > 0, channels <= 8,
              flags & kAudioFormatFlagIsPacked != 0 else { return nil }

        let sampleFormat: SampleFormat
        let bytesPerSample: UInt32
        if flags & kAudioFormatFlagIsFloat != 0,
           format.mBitsPerChannel == 32,
           flags & kAudioFormatFlagIsBigEndian == 0 {
            sampleFormat = .float32
            bytesPerSample = 4
        } else if flags & kAudioFormatFlagIsSignedInteger != 0,
                  format.mBitsPerChannel == 16,
                  flags & kAudioFormatFlagIsBigEndian == 0 {
            sampleFormat = .int16
            bytesPerSample = 2
        } else {
            return nil
        }
        guard format.mBytesPerFrame == bytesPerSample * UInt32(planar ? 1 : channels) else {
            return nil
        }

        self.sampleFormat = sampleFormat
        channelCount = channels
        nonInterleaved = planar
        output = configuration.gainLimiter
        equalizerActive = configuration.equalizer.isActive
        equalizers = equalizerActive
            ? (0..<channels).map { _ in
                AudioEqualizerState(
                    configuration: configuration.equalizer,
                    sampleRate: format.mSampleRate
                )
            }
            : []
        compressor = configuration.compressor.isEnabled
            ? AudioCompressorState(
                configuration: configuration.compressor,
                sampleRate: format.mSampleRate
            )
            : nil
    }

    func reset() {
        for index in equalizers.indices { equalizers[index].reset() }
        compressor?.reset()
    }

    /// Called on the render thread. Its loops and state updates allocate no
    /// memory. The compressor takes a shared peak across channels per frame.
    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0, equalizerActive || compressor != nil || output.isEnabled else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count == (nonInterleaved ? channelCount : 1) else { return }
        let bytesPerSample = sampleFormat == .float32 ? 4 : 2
        for index in buffers.indices {
            let channelsInBuffer = nonInterleaved ? 1 : channelCount
            guard buffers[index].mNumberChannels == UInt32(channelsInBuffer),
                  buffers[index].mData != nil,
                  Int(buffers[index].mDataByteSize) >= frames * channelsInBuffer * bytesPerSample
            else { return }
        }

        // Eight channels fit in a value stored on the stack. Keep EQ's Float
        // output here until after linked compression and limiting; writing an
        // intermediate Int16 value would clip before compression could act.
        var frameSamples = SIMD8<Float>.zero
        for frame in 0..<frames {
            var peak: Float = 0
            for channel in 0..<channelCount {
                let input = read(buffers, frame: frame, channel: channel)
                let processed = equalizerActive
                    ? equalizers[channel].process(input)
                    : (input.isFinite ? input : 0)
                frameSamples[channel] = processed
                peak = max(peak, abs(processed))
            }
            let compressionGain = compressor?.gain(for: peak) ?? 1
            for channel in 0..<channelCount {
                let processed = frameSamples[channel] * compressionGain
                let result = output.isEnabled
                    ? AudioGainLimiter.limit(processed, gain: output.gain, knee: output.kneeStart)
                    : processed
                write(result, to: buffers, frame: frame, channel: channel)
            }
        }
    }

    @inline(__always)
    private func sampleOffset(frame: Int, channel: Int) -> (buffer: Int, sample: Int) {
        nonInterleaved ? (channel, frame) : (0, frame * channelCount + channel)
    }

    @inline(__always)
    private func read(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        frame: Int,
        channel: Int
    ) -> Float {
        let offset = sampleOffset(frame: frame, channel: channel)
        let data = buffers[offset.buffer].mData!
        switch sampleFormat {
        case .float32:
            return data.assumingMemoryBound(to: Float.self)[offset.sample]
        case .int16:
            return Float(data.assumingMemoryBound(to: Int16.self)[offset.sample]) / 32_768
        }
    }

    @inline(__always)
    private func write(
        _ value: Float,
        to buffers: UnsafeMutableAudioBufferListPointer,
        frame: Int,
        channel: Int
    ) {
        let offset = sampleOffset(frame: frame, channel: channel)
        let data = buffers[offset.buffer].mData!
        switch sampleFormat {
        case .float32:
            data.assumingMemoryBound(to: Float.self)[offset.sample] = value
        case .int16:
            let scaled = (value * 32_768).rounded()
            data.assumingMemoryBound(to: Int16.self)[offset.sample] = Int16(
                min(max(scaled, -32_768), 32_767)
            )
        }
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
    var processor: AudioPCMProcessor?
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
                state.processor = AudioPCMProcessor(
                    configuration: state.configuration,
                    format: format.pointee
                )
                state.sampleRate = format.pointee.mSampleRate
                state.silenceState.reset()
                state.metrics?.prepare(sampleRate: state.sampleRate)
            },
            unprepare: { tap in
                let state = tapStorage(for: tap)
                state.processor = nil
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
                guard status == noErr else { return }

                let state = tapStorage(for: tap)
                guard let processor = state.processor else { return }
                if sourceFlags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
                    processor.reset()
                    state.silenceState.reset()
                }
                let sourceFrameCount = Int(framesOut.pointee)
                guard sourceFrameCount > 0 else { return }

                var keptFrameCount = sourceFrameCount
                if let silenceConfiguration = state.configuration.silenceTrimming,
                   processor.supportsSilenceTrimming {
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

                processor.process(bufferList, frames: keptFrameCount)
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
