import AVFoundation
import MediaToolbox

enum AudioProcessingTapError: Error, Equatable {
    case creationFailed(OSStatus)
    case noAudioTrack
}

/// Owns the immutable configuration and the format reported by MediaToolbox.
/// Prepare/process/unprepare are serialized by the audio machinery.
private final class AudioProcessingTapStorage {
    let configuration: AudioGainLimiterConfiguration
    var processesFloat32 = false

    init(configuration: AudioGainLimiterConfiguration) {
        self.configuration = configuration
    }
}

enum AudioProcessingTapFactory {
    /// Creates a real MediaToolbox tap but does not attach it to live playback.
    /// Unsupported PCM formats pass through untouched; production activation
    /// requires an AudioConverter allocated during `prepare`, never in `process`.
    static func makeGainTap(
        configuration: AudioGainLimiterConfiguration
    ) throws -> MTAudioProcessingTap {
        let initialStorage = AudioProcessingTapStorage(configuration: configuration)
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
            },
            unprepare: { tap in
                tapStorage(for: tap).processesFloat32 = false
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

                let configuration = tapStorage(for: tap).configuration
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
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioProcessingTapError.noAudioTrack
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = try makeGainTap(configuration: configuration)
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
