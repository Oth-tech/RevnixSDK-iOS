# Changelog

## Unreleased

### Added

- **`logAdRevenue(revenue:currency:network:mediation:adUnit:placement:format:eventId:)`.**
  Reports impression-level ad revenue from your mediation SDK's paid-event
  callback (AdMob `paidEventHandler`, AppLovin MAX `didPayRevenue`).
  Fire-and-forget like the other beacons — a revenue that is not finite or
  not greater than 0 is refused with a diagnostic and sends no request.
  (PT8)
- **SKAdNetwork registration.** `registerInstall(platform:appVersion:)` now
  registers the app for SKAdNetwork attribution once per install — without
  that call Apple generates no install postback at all. Requires the app's
  `Info.plist` to carry `NSAdvertisingAttributionReportEndpoint` set to
  `https://revnix.io` — the bare apex, the same for every customer, since
  Apple keeps only the registrable domain and drops a subdomain or path.
- **`updateSkanConversionValue(_:coarse:lockWindow:)`.** Reports a SKAdNetwork
  conversion value (fine 0…63, plus an optional `RevnixCoarseValue` and window
  lock on iOS 16.1+) to Apple — never to Revnix. A value outside 0…63 is
  refused with a diagnostic. `RevnixConfig(skan: false)` opts out of
  SKAdNetwork entirely.
- **`getAttribution()` and `onAttribution`.** The install-attribution verdict
  for this customer — `RevnixAttribution(installMatch, attributedAt, …)` or
  nil when none has been recorded yet or the read failed. Never throws.
  `RevnixConfig(onAttribution:)` delivers it on the main actor whenever it
  CHANGES, never twice for the same verdict, and is what turns the automatic
  refresh after the install and Apple Search Ads reports on: without the
  handler the SDK never asks for the verdict on its own. (AT11)
- **`lastDeepLink()`.** The most recent link seen by `handleDeepLink` or a
  delivered deferred deep link, as `LastDeepLink(url, receivedAt)` or nil,
  persisted on the device so it can be read again after login or onboarding.
- **`onDeferredDeepLink`.** `RevnixConfig(onDeferredDeepLink:)` delivers the
  link a customer clicked before installing (probabilistic match from a
  same-network click inside the link's click window, 1 hour by default,
  configurable per link up to 24 hours) at most once per install, on the
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
