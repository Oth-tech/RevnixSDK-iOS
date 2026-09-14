# Changelog

## Unreleased

### Added

- **Dashboard QR/link paywall preview.** A preview link
  (`<scheme>://revnix-preview?revnix_preview=<token>`) handed to
  `handleDeepLink(_:)` fetches the draft paywall and hands it to
  `onImplicitPaywall` — detect it via `resolution.placementKey ==
  revnixPreviewPlacementKey` / `resolution.preview == true`. Never charges
  (`RevnixPaywallView` blocks purchases on it — a tap shows a "Purchases are
  disabled in preview" alert) and never sends paywall analytics.
- **First published release.** The SDK is installable from Swift Package
  Manager by pointing Xcode at this repository — the git tag a release cuts is
  what SPM resolves — and from CocoaPods as the `Revnix` pod. Nothing about
  the API changed to make this possible; the code was simply never tagged.

## 0.3.0

Never released. The version the podspec and `RevnixClient.sdkVersion` carried
before this repository had a release pipeline, kept here so the sequence does
not appear to start mid-air.
