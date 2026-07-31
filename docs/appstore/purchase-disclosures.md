# Earshot purchase disclosures

Status: implementation copy for issue #638. The published privacy page must
match `docs/privacy/index.html` before submission.

## Earshot Plus subscriptions

The paywall displays the localized StoreKit product name and price. For every
subscription it also displays, before the purchase button:

> Payment is charged to your Apple ID when you confirm. Auto-renews unless
> cancelled at least 24 hours before the current period ends. Your Apple ID is
> charged for renewal within 24 hours before the current period ends. Manage or
> cancel in your App Store account settings.

The paywall links to Earshot's Privacy Policy and Apple's Standard EULA. The
localized price and billing period are prepended to the disclosure at runtime.

## Lifetime purchase

> One-time purchase. Not a subscription — charged once, yours forever.

## Optional tips

> Tips are optional, one-time consumable purchases processed by Apple. They do
> not unlock Earshot Plus and are not subscriptions.

The tip screen also links to Earshot's Privacy Policy and Apple's Standard
EULA.

## Canonical URLs

- Privacy Policy: https://payown.media/earshot-privacy-policy/
- Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
