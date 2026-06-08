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
