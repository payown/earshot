# Audio-processing spike for #570 and #571

Date: 2026-08-23

## Decision

Keep the shipping `AVPlayer` path unchanged while proving a shared decoded-PCM
processing boundary. The first spike adds:

- an allocation-free Float32 gain stage with a bounded smooth-knee limiter;
- pure silence classification and actual-frame time-saved accounting;
- a real `MTAudioProcessingTap` lifecycle and file-audio-mix factory;
- no setting, schema change, playback attachment, or spoken UI.

This is intentionally infrastructure, not completion of either issue.

## Apple API constraints verified

- A tap render callback is real-time work: it must not allocate or block.
- The callback may request more source data to produce the requested output frame
  count, which can support future silence compression with a prepared buffer.
- Prepare may run more than once and is where buffers/converters must be allocated.
- `AVPlayerItem.audioMix` works for file-based media but Apple explicitly does not
  support it for HTTP Live Streaming. HLS needs a baseline fallback or a different
  playback topology.
- The processing format is not guaranteed Float32. This spike processes Float32
  and passes other formats through; production requires an `AudioConverter`
  allocated during prepare.

## Requirements before enabling volume boost

1. Add prepare-time conversion for every PCM format observed on device.
2. Add a look-ahead or envelope limiter and compare it against the current smooth
   knee with speech, music, mono, stereo, Bluetooth, AirPlay, speaker, and CarPlay.
3. Attach the mix before playback begins and preserve preload, stall recovery,
   interruption, route, seek, time-pitch, and gapless behavior.
4. Decide the global steps and per-episode persistence representation before a UI
   or schema change.
5. Measure render cost, heat, and VoiceOver responsiveness on Michael’s iPhone.

## Requirements before enabling silence trimming

1. Build a prepare-allocated source/output ring buffer that consumes additional
   quiet source frames while returning the exact requested output count.
2. Preserve speech boundaries with attack/release hysteresis and short crossfades.
3. Reset state on start-of-stream/discontinuity and propagate end-of-stream.
4. Derive saved time only from source frames actually consumed minus output frames;
   detected quiet time alone must never inflate Stats.
5. Define behavior for HLS and unsupported formats before exposing the global or
   per-podcast toggle.

## Exit criteria for the spike

- deterministic DSP and lifecycle tests pass;
- the entire existing suite remains green with the processor unattached;
- no user-facing changelog entry or build distribution is created until physical
  listening demonstrates an audible feature rather than dormant infrastructure.
