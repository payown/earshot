# Dynamic-range compression and equalizer plan

StartTesting feature: `1f0a5c06-1e92-428f-af56-b0e614cd0624`.

## Current behavior and scope

- Volume boost multiplies PCM samples and applies a soft output limit. It does
  not track the signal envelope or reduce the difference between quiet and loud
  passages. Silence trimming is a separate timeline effect.
- Use device-local global defaults, like volume boost. No model/schema change or
  cloud sync is needed. Existing per-episode volume boost continues to work.
- Both new effects default off. Off leaves the existing playback path and
  output unchanged. They can be enabled independently.

## Controls

- Compression: Off, Light, Balanced, Strong. Each level has a fixed threshold,
  ratio, attack, release, and modest makeup gain. Plain-language Settings text
  explains that it narrows loud/quiet differences; it is distinct from boost.
- Equalizer: one enable switch and adjustable Bass, Speech, and Treble bands.
  Each band offers −6, −3, 0, +3, and +6 dB. Zero is neutral. Native adjustable
  controls preserve VoiceOver flick adjustment and Dynamic Type behavior.
- Changes persist locally and reattach the processor to the current item. The
  same settings apply to downloaded files, regular podcast media, and Personal
  Audio when AVPlayer supports an audio mix. HLS/unsupported formats retain the
  existing unprocessed playback fallback.

## Processing and verification

1. Reuse the existing MediaToolbox audio tap. Prepare channel/filter/envelope
   state before the render callback; do not allocate, lock, log, or access
   SwiftData in that callback.
2. Process equalization, then linked-channel envelope compression, then the
   existing volume boost and soft output limit. Bound output below full scale.
   Preserve silence-trimming behavior and its accounting.
3. Test off-state identity, compression of alternating loud/quiet tones, EQ
   frequency response and channel separation, clipping limits, persistence,
   and live setting reattachment. Run focused tests and the full CI suite.
4. Physical listening and route checks remain acceptance work: speech/music,
   seeks, speed changes, interruptions, background playback, Bluetooth/AirPlay,
   HLS fallback, VoiceOver responsiveness, heat, and battery use. Simulator
   tests alone cannot establish those outcomes.
