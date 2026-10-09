<p align="center">
  <a href="https://www.revnix.io"><img src="https://raw.githubusercontent.com/Oth-tech/RevnixSDK-iOS/main/.github/assets/logo.png" width="360" alt="Revnix"></a>
</p>

<h1 align="center">Subscriptions, Paywalls and Attribution<br>for Your iOS App</h1>

<p align="center">
  <a href="https://swiftpackageindex.com/Oth-tech/RevnixSDK-iOS"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FOth-tech%2FRevnixSDK-iOS%2Fbadge%3Ftype%3Dplatforms" alt="platforms"></a>
  <a href="https://swiftpackageindex.com/Oth-tech/RevnixSDK-iOS"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FOth-tech%2FRevnixSDK-iOS%2Fbadge%3Ftype%3Dswift-versions" alt="swift versions"></a>
  <a href="https://github.com/Oth-tech/RevnixSDK-iOS/blob/main/LICENSE"><img src="https://img.shields.io/github/license/Oth-tech/RevnixSDK-iOS?color=2f6fe0" alt="license"></a>
</p>

<p align="center">
  <a href="https://www.revnix.io"><b>Website</b></a> •
  <a href="https://www.revnix.io/docs/ios"><b>Docs</b></a> •
  <a href="https://www.revnix.io/docs/ios/setup#config"><b>API Reference</b></a>
</p>

![Revnix: subscriptions, paywalls and attribution for mobile apps](https://raw.githubusercontent.com/Oth-tech/RevnixSDK-iOS/main/.github/assets/hero.png)

Revnix SDK makes in-app subscriptions, paywalls and attribution for iOS fast and easy. One package buys through StoreKit 2, validates the receipt on the server and unlocks the entitlement, offline-correct, with zero dependencies. iOS 16+, macOS 13+, tvOS 16+, watchOS 9+.

## Table of Contents

- [Why Revnix?](#why-revnix)
- [Getting Started](#getting-started)
- [Quick start](#quick-start)
- [Purchases and entitlements without server code](#purchases-and-entitlements-without-server-code)
- [Paywalls that update without app releases](#paywalls-that-update-without-app-releases)
- [A/B tests with a built-in holdout](#ab-tests-with-a-built-in-holdout)
- [Attribution and deep links](#attribution-and-deep-links)
- [Real-time analytics for your iOS app](#real-time-analytics-for-your-ios-app)
- [Compatibility](#compatibility)
- [Documentation](#documentation)
- [Support](#support)
- [Contributing](#contributing)
- [Like Revnix SDK?](#like-revnix-sdk)
- [License](#license)

## Why Revnix?

- [Purchases in one call](https://www.revnix.io/docs/ios/register-purchases). `RevnixStoreKit.purchase` opens the App Store sheet, validates the receipt on the server and grants the entitlement. No server code.
- [Entitlements that work offline](https://www.revnix.io/docs/ios/check-entitlements). Entitlement checks are cached on device, so a user who paid stays unlocked without a network.
- [Remote paywalls](https://www.revnix.io/docs/ios/show-paywalls). Design paywalls in the dashboard, pick from nine templates and ship copy, prices and layout changes without an app release.
- [A/B tests and holdouts](https://www.revnix.io/docs/ios/show-paywalls). Split a placement between variants, measure revenue per user and ship the winner from the dashboard.
- [Attribution and deep links](https://www.revnix.io/docs/ios/track-events). Install attribution, deferred deep links, Apple Search Ads, SKAdNetwork and MMP forwarding, all from the same SDK.
- [Privacy and tracking](https://www.revnix.io/docs/app-tracking-transparency). App Tracking Transparency support and a privacy manifest ship with the SDK.

## Getting Started

Requires iOS 16+ / macOS 13+ / tvOS 16+ / watchOS 9+ and Swift 5.9.

Swift Package Manager. In Xcode: **File → Add Package Dependencies…**, paste
`https://github.com/Oth-tech/RevnixSDK-iOS.git`, and pick the `Revnix`
library. Or in `Package.swift`:

```swift
.package(url: "https://github.com/Oth-tech/RevnixSDK-iOS.git", from: "1.5.0")
```

Releases are the `vX.Y.Z` tags on this repository. CocoaPods is not published.

Use the **publishable** key (`rvx_pk_…`) only. Secret keys must never ship in a binary. Your API key is in the dashboard under Settings. See [Setup](https://www.revnix.io/docs/ios/setup).

## Quick start

```swift
import Revnix

// 1. Configure once at app start
let client = RevnixClient(RevnixConfig(
    apiKey: "rvx_pk_live_…",
    baseURL: URL(string: "https://your-deployment.convex.site")!
))

// 2. Replay store transactions + drain the offline queue
let observer = RevnixStoreKit.startObserving(client: client)
await client.retryPendingPurchases()
await client.registerInstall(platform: "ios")

// 3. Buy: opens the store sheet, validates the receipt, grants the entitlement
if let result = try await RevnixStoreKit.purchase(product, client: client) {
    _ = try await client.waitForEntitlements(seq: result.seq)
}

// 4. Check access anywhere
if await client.isEntitled("pro") { unlockPro() }
```

## Purchases and entitlements without server code

**Revnix handles the hard parts of subscriptions in a small, developer-friendly SDK.**

- `RevnixStoreKit.purchase` runs the whole flow: store sheet, server-side receipt validation with the StoreKit 2 JWS as proof, entitlement, transaction finish. `RevnixStoreKit.restore` brings purchases back on a new device.
- Renewals and purchases on other devices arrive on their own and are registered automatically.
- A network blip keeps paying customers unlocked offline; a revoked key still locks them out.
- Already using your own StoreKit code? Call `client.registerPurchase` instead. See [Register purchases](https://www.revnix.io/docs/ios/register-purchases).

## Paywalls that update without app releases

![Revnix paywall builder with a live device preview](https://raw.githubusercontent.com/Oth-tech/RevnixSDK-iOS/main/.github/assets/paywalls.png)

With the [Revnix paywall builder](https://www.revnix.io/docs/ios/show-paywalls) you design the paywall in the dashboard and render it natively in your app.

- **Native rendering**: `resolvePlacement` returns the config, `RevnixPaywallView` draws it with SwiftUI and hands you the selected package to buy.
- **Nine templates** plus builder designs: pick a layout, theme and accent, then edit copy, packages and badges.
- **Prices from StoreKit**: you supply titles and localized prices from StoreKit, so display never disagrees with the charge.
- **Localized**: `RevnixClient.setLocale` forces every designed paywall into a given language.

```swift
let resolution = try await client.resolvePlacement("paywall_main")
if let paywall = resolution.paywall {
    RevnixPaywallView(
        config: paywall.config,
        packages: products.map {
            RevnixPaywallPackage(packageId: packageId(for: $0), title: $0.displayName, priceLabel: $0.displayPrice)
        },
        onPurchase: { packageId in purchase(packageId) },
        client: client,
        placementKey: "paywall_main",
        paywallId: paywall.paywallId
    )
}
```

## A/B tests with a built-in holdout

![Revnix A/B test results with a winner and credible intervals](https://raw.githubusercontent.com/Oth-tech/RevnixSDK-iOS/main/.github/assets/ab-test.png)

- `resolvePlacement` sends the customer id, so a running A/B test serves that customer's variant, sticky across identity merges.
- `experiment` metadata on the response tells you which variant was shown, for your own analytics.
- A **holdout** variant shows no paywall at all, to measure what the paywall is really worth.
- `setAttributes` supplies the customer attributes a test's audience conditions read.

## Attribution and deep links

![Revnix ROAS by channel report](https://raw.githubusercontent.com/Oth-tech/RevnixSDK-iOS/main/.github/assets/attribution.png)

- **Install attribution**: `registerInstall` mints the Apple Search Ads token and registers SKAdNetwork, once per install. See [Track events](https://www.revnix.io/docs/ios/track-events).
- **SKAdNetwork conversion values**: report progress with `client.updateSkanConversionValue`.
- **Deep links**: `client.handleDeepLink` reports an opened URL; `onDeferredDeepLink` delivers a link matched to the install after an App Store detour. See [Deferred deep links](https://www.revnix.io/docs/deferred-deep-links).
- **Attribution verdicts**: `client.getAttribution` or the `onAttribution` callback report which campaign, link or referrer an install came from; `client.setAttribution` forwards Adjust/AppsFlyer attribution callbacks.
- **Tracking permission**: `client.requestTrackingAuthorization` shows Apple's App Tracking Transparency prompt. See [App Tracking Transparency](https://www.revnix.io/docs/app-tracking-transparency).

## Real-time analytics for your iOS app

![Revnix overview dashboard with revenue and MRR](https://raw.githubusercontent.com/Oth-tech/RevnixSDK-iOS/main/.github/assets/analytics.png)

- Install reports, paywall view/close/interaction beacons feed funnels and conversion reports.
- `client.track` reports any custom in-app event, e.g. `level_up`.
- `client.logAdRevenue` reports impression-level ad revenue from a mediation SDK's paid callback, feeding the ROAS table.
- `client.setPushToken` enables uninstall measurement. See [Uninstall measurement](https://www.revnix.io/docs/uninstall-measurement).

## Compatibility

| Platform | Minimum |
|---|---|
| iOS | 16.0 |
| macOS | 13.0 |
| tvOS | 16.0 |
| watchOS | 9.0 |
| Swift | 5.9 |
| Xcode | 15 or later |
| Store integration | StoreKit 2 only |
| Dependencies | none |

## Documentation

- [Overview](https://www.revnix.io/docs/ios)
- [Setup](https://www.revnix.io/docs/ios/setup)
- [Identify users](https://www.revnix.io/docs/ios/identify-users)
- [Register purchases](https://www.revnix.io/docs/ios/register-purchases)
- [Check entitlements](https://www.revnix.io/docs/ios/check-entitlements)
- [Show paywalls](https://www.revnix.io/docs/ios/show-paywalls)
- [Track events](https://www.revnix.io/docs/ios/track-events)
- [Privacy manifest](https://www.revnix.io/docs/privacy-manifest)

## Support

- Email [support@revnix.io](mailto:support@revnix.io) with questions, bugs or feature requests.
- Open an issue on [GitHub](https://github.com/Oth-tech/RevnixSDK-iOS/issues).

## Contributing

- Found a bug or want a feature? Open an issue, we read all of them.
- Pull requests are welcome: run `swift test` before opening one.

## Like Revnix SDK?

So do we! Star the repo ⭐️ and make our developers happy.

## License

Revnix SDK is available under the MIT license. See [LICENSE](https://github.com/Oth-tech/RevnixSDK-iOS/blob/main/LICENSE) for details.
