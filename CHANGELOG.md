# Changelog

## Unreleased

## 1.8.0 (2026-10-14)

### Added

- Paywall blocks: onboarding `screens` shown before the paywall, with `next`/`back` actions on text, image and button blocks and progress dots while an intro screen is showing.

## 1.7.0 (2026-10-13)

### Added

- Paywall blocks: `timer` (countdown to a date or from when the paywall opens), `video` (muted looping clip with a poster), `toggle` (free-trial switch that flips the selected package) and the card `carousel` layout (swipeable pages with dots and optional auto-advance).

## 1.6.0 (2026-10-12)
## 1.6.0 (2026-10-12)

### Added

- `flushEvents()` sends queued events now. `track` and `logPaywallEvent` are
  queued on disk (up to 1000) and sent in batches: at 20 queued, 10 s after
  the first, on background, and on the next launch. A transient failure
  keeps them.
- `preload(_:)` fetches placements ahead of time and warms the paywall images.

### Changed

- `resolvePlacement` answers from a cache under 24 h old and refreshes it in
  the background, so a paywall opens without waiting on the network.
- Entitlement reads with a cached snapshot time out after 3 s instead of 10 s.
- The purchase retry queue keeps at most 100 purchases and drops ones queued
  more than 30 days ago.

## 1.5.0 (2026-10-08)
## 1.5.0 (2026-10-08)
## 1.5.0 (2026-10-08)
## 1.5.0 (2026-10-08)

Changes since 1.4.1 were not recorded here; see the commit log.

## 1.4.1 (2026-10-08)
## 1.4.1 (2026-10-08)
## 1.4.1 (2026-10-08)
## 1.4.1 (2026-10-08)
## 1.4.1 (2026-10-08)
## 1.4.1 (2026-10-08)
## 1.4.1 (2026-10-08)
## 1.4.1 (2026-10-08)

### Changed

- Versioning now follows the Revnix release train: this jumps from 0.4.0 to
  1.4.1 to match `react-native-revnix` and `revnix-capacitor`, no API
  changes.

## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)
## 0.4.0 (2026-10-08)

### Added

- `RevnixConfig.deviceIntegrity` attaches Apple App Attest evidence to
  install requests so the server can verify a genuine app and device. Off
  by default; waits up to 10s on first launch.
- `PrivacyInfo.xcprivacy` ships in the package (SwiftPM resource, CocoaPods
  `Revnix_Privacy` bundle), declaring User ID, Device ID, Purchase History,
  Product Interaction and Advertising Data use, not for tracking.
- `requestTrackingAuthorization()` shows Apple's App Tracking Transparency
  prompt and returns its status, storing `att_status` and `idfa` on the
  customer. Needs `NSUserTrackingUsageDescription` in `Info.plist`.
- `RevnixConfig.attWaitTimeout` holds the first `registerInstall` report for
  up to this many seconds while the ATT prompt is unanswered. Off by
  default.
- `track(_:properties:eventId:)` reports a custom in-app event to
  `POST /v1/events`, landing as `custom.<event>` on the ledger. `event` must
  match `^[a-z0-9_]{1,64}$`; not for purchases.
- `logAdRevenue(revenue:currency:network:mediation:adUnit:placement:format:eventId:)`
  reports impression-level ad revenue from your mediation SDK's paid-event
  callback. Fire-and-forget; a revenue that isn't finite or positive is
  refused.
- `setAttribution(provider:network:campaign:adGroup:creative:)` forwards an
  MMP's attribution callback (Adjust, AppsFlyer, Singular, Branch, Kochava,
  Tenjin, Airbridge) so Revnix credits revenue to the right network and
  campaign.
- `registerInstall(platform:appVersion:)` now registers the app for
  SKAdNetwork attribution once per install. Requires `Info.plist`'s
  `NSAdvertisingAttributionReportEndpoint` set to the bare apex
  `https://revnix.io`.
- `updateSkanConversionValue(_:coarse:lockWindow:)` reports a SKAdNetwork
  conversion value (0...63, optional coarse value, window lock on
  iOS 16.1+) to Apple, never Revnix. `RevnixConfig(skan: false)` opts out.
- `getAttribution()` and `onAttribution` return the install-attribution
  verdict for this customer. `RevnixConfig(onAttribution:)` delivers it on
  the main actor whenever it changes, never twice.
- `lastDeepLink()` returns the most recent link seen by `handleDeepLink` or
  a delivered deferred deep link, persisted on the device for reading after
  login.
- `RevnixConfig(onDeferredDeepLink:)` delivers the link a customer clicked
  before installing, matched probabilistically within the link's click
  window (1 hour by default, up to 24h), once per install.
- `resolveDeepLink(_:)` unwraps a link an email provider (Mailchimp,
  SendGrid) rewrote through its own tracking domain, back to the app's deep
  link. Never throws; a failed lookup returns the input unchanged.
- A preview link (`<scheme>://revnix-preview?revnix_preview=<token>`) handed
  to `handleDeepLink(_:)` fetches the draft paywall for `onImplicitPaywall`.
  Detect it via `resolution.preview == true`; it never charges or sends
  analytics.
- `RevnixClient.setLocale(_:)` forces the paywall language for every paywall
  rendered after the call, including the links-block footer labels; `nil`
  clears it.
- `setPushToken(_:)` (`String` or `Data`) registers the push token for
  uninstall measurement.
- `registerInstall` now carries a Keychain-persisted device key so the
  server can flag reinstalls.
- `previousSessionMs` on `session_start` reports the length of the previous
  session, in milliseconds.

### Changed

- `handleDeepLink(_:)` now records every link's attribution even without an
  `onImplicitPaywall` handler; a paywall shows only when implicit placements
  and `deeplink_open` are configured. `start()` after `stop()` resumes this.

## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0
## 0.3.0

Never released. The version the podspec and `RevnixClient.sdkVersion` carried
before this repository had a release pipeline, kept here so the sequence does
not appear to start mid-air.
