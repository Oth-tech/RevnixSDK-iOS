# Changelog

## Unreleased

### Added

- **`lastDeepLink()`.** The most recent link seen by `handleDeepLink` or a
  delivered deferred deep link, as `LastDeepLink(url, receivedAt)` or nil,
  persisted on the device so it can be read again after login or onboarding.
- **`onDeferredDeepLink`.** `RevnixConfig(onDeferredDeepLink:)` delivers the
  link a customer clicked before installing — probabilistic match from a
  same-network click within the last hour — at most once per install, on the
  main actor, from `registerInstall(platform:appVersion:)`'s response.
  `registerInstall` now reports the platform for you when none is passed. (REV-299)
- **`resolveDeepLink(_:)`.** Unwraps a link an email service provider
  (Mailchimp, SendGrid, …) rewrote through its own click-tracking domain back
  to the app's own deep link, so it can be routed and handed to
  `handleDeepLink(_:)`. Never throws — a lookup failure returns the input URL
  unchanged. (REV-299)
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
