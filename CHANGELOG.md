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

### Changed

- **Deep links always record their attribution.** `handleDeepLink(_:)`
  reports every ordinary link, so its `link.*` attributes land on the
  customer with no `onImplicitPaywall` handler and no `deeplink_open`
  placement. A paywall still presents only when implicit placements are on
  and `deeplink_open` is configured; otherwise the report carries
  `resolve: false` and the server stores the link facts only. `start()`
  after `stop()` now resumes deep-link reporting even without a handler.

## 0.3.0

Never released. The version the podspec and `RevnixClient.sdkVersion` carried
before this repository had a release pipeline, kept here so the sequence does
not appear to start mid-air.
