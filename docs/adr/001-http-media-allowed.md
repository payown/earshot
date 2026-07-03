# ADR 001: Allow HTTP media streams (NSAllowsArbitraryLoadsForMedia)

**Status:** Accepted  
**Date:** 2026-06-08  
**Deciders:** Michael Babcock (Payown Media LLC)

## Context

iOS App Transport Security (ATS) blocks plain HTTP connections by default. Earshot plays podcast audio streams sourced from RSS feeds published by independent creators and organisations. A substantial portion of these feeds still serve audio over HTTP, not HTTPS. This is especially common among:

- Older feeds that predate widespread HTTPS adoption
- Feeds from non-profit and community organisations (ACB, BITS, etc.) that Earshot is specifically built to serve
- Feeds hosted on low-budget infrastructure without HTTPS configured

Blocking HTTP audio would silently prevent playback for these users with no clear error message.

## Decision

Set `NSAllowsArbitraryLoadsForMedia = true` in `ios/Runner/Info.plist`.

This exception applies **only to media content** (audio and video streams). It does not affect general networking — all API calls (Podcast Index search, feed fetching, Sentry, PostHog) use HTTPS exclusively and are unaffected by this setting.

## Consequences

**Accepted risk:** Audio streams served over HTTP are not protected against on-path content tampering. An attacker on the same network as the listener could in theory replace the audio payload in transit. We accept this risk because:

1. The attack requires a network-level adversary specifically targeting audio content.
2. The data at risk is podcast audio, not user credentials or personal data.
3. The benefit (accessibility for a community we exist to serve) outweighs the theoretical risk.

**Future consideration:** Opportunistically prefer HTTPS stream URLs when a feed provides both. Surface a non-blocking indicator in the UI for HTTP-only feeds so technically aware users can make an informed choice. Revisit this ADR if a significant portion of the target feed catalogue moves to HTTPS.

## Implementation (SwiftUI rebuild, #387)

Implemented on the SwiftUI app 2026-07-02:

- `Earshot/App/Info.plist` now sets `NSAllowsArbitraryLoadsForMedia = true` and
  no longer sets the blanket `NSAllowsArbitraryLoads`. Plain HTTP is therefore
  permitted only for audio/video loaded through AVFoundation (the AVPlayer
  streaming path).
- Auditing the code showed the original consequence analysis was incomplete:
  feed XML, artwork, episode downloads, and ID3 tag reads all go through
  `URLSession`, not AVFoundation, so a media-only policy would block those for a
  plain-HTTP host. To keep HTTPS-capable hosts working, those non-media fetches
  are upgraded `http`→`https` via `Core/Networking/SecureURL.swift`
  (`HTTPClient`, `ArtworkCache`, `DownloadManager`). The AVPlayer stream URL is
  deliberately **not** upgraded, so audio from an HTTP-only host still streams
  under the media exemption.
- Net effect: an HTTP-only host loses artwork/refresh/download (its data was
  never protected anyway) but its audio still plays; every host that also serves
  HTTPS is now fully protected.
