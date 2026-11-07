# RevnixSDK-iOS

Native Swift SDK for Revnix: StoreKit 2 purchases, offline-correct entitlements, paywall rendering, attribution. Talks to the backend in `../revnix-app` (Convex HTTP routes under `/v1`, base URL `https://<deployment>.convex.site`). Public repo `Oth-tech/RevnixSDK-iOS`, default branch `main`. Zero dependencies (Foundation, StoreKit, CryptoKit, SwiftUI; AdServices / AdAttributionKit / AppTrackingTransparency / DeviceCheck guarded by `canImport`).

## Package
- `Package.swift`: swift-tools-version 5.9; platforms iOS 16 / macOS 13 / tvOS 16 / watchOS 9; product and target `Revnix` (`Sources/Revnix`, resource `PrivacyInfo.xcprivacy`); test target `RevnixTests` (XCTest, resources `Revnix.storekit` + two `paywall-*-wire.json`).
- `Revnix.podspec` exists but CocoaPods is NOT published (README says so). It is only the version source for `scripts/release.sh`. The version lives here AND in `RevnixClient.sdkVersion`; both must match (release.sh and CI enforce it).
- SwiftPM release = the `vX.Y.Z` git tag. Nothing is pushed to a registry.
- Consumed as a git submodule by `../RevnixSDK-Flutter` (`ios/revnix_flutter/Revnix`) and `../RevnixSDK-Capacitor` (`ios/Revnix`). They re-pin at their next release; never rewrite history here.

## Layout (`Sources/Revnix/`)
- `RevnixClient.swift` (~2100 lines): `public actor RevnixClient`. Entitlements (network-first, signed cache, 30 s soft TTL, 14-day offline window), purchase registration + persistent retry queue, placements/offerings, event queue, attribution, SKAN, ATT, deep links, install registration, App Attest (`deviceIntegrity`), `sdkVersion`.
- `RevnixConfig.swift`: `RevnixConfig` (apiKey, baseURL, storage, 10 s timeout, callbacks `onImplicitPaywall` / `onDeferredDeepLink` / `onAttribution`, `skan`, `attWaitTimeout`, `deviceIntegrity`), `RevnixDiagnostic`, `RevnixAttribution`.
- `StoreKitGlue.swift`: `RevnixStoreKit.startObserving` (Transaction.updates, StoreKit 2 only), `.purchase`, `.restore`. Always sends the JWS as proof.
- `Skan.swift`, `Tracking.swift` (ATT + IDFA), `DeviceFacts.swift` (`X-Revnix-Device` header), `ImplicitPlacements.swift`, `Storage.swift` (`RevnixStorage`, `MemoryStorage`, `FileStorage` JSON under Application Support/revnix/), `Models.swift`, `RevnixError.swift`.
- Paywall UI: `RevnixPaywallView`, `RevnixPaywallBlockView`, `PaywallBlocks`, `PaywallBlockGeometry`, `PaywallBackground`, `PaywallLocalization`, `PaywallRenderRules`. They render the backend's paywall JSON; block/schema changes follow `revnix-app`.
- `PrivacyInfo.xcprivacy`: `NSPrivacyTracking` true; DeviceID + PurchaseHistory. `NSPrivacyTrackingDomains` is omitted on purpose (listing the customer's convex.site host would make iOS block the whole SDK for ATT-denied users). `PrivacyManifestTests` guards it.

## Wire contract
- Headers: `Authorization: Bearer <rvx_pk_…>` (publishable key only; secret keys never ship), `X-Revnix-SDK: revnix-swift/<ver>`, optional `X-Revnix-Device`, `X-Revnix-Bg-Failures`. `identify`/alias are server-side; the SDK does not call `/v1/identify`.
- Endpoints (grep `"/v1/` in RevnixClient.swift): `/v1/installs`, `/v1/config`, `/v1/placements/{key}/offering`, `/v1/placements/triggered`, `/v1/purchases`, `/v1/customers/{id}/entitlements|attribution|attributes`, `/v1/attribution`, `/v1/events`, `/v1/paywalls/viewed|closed|events`, `/v1/paywalls/preview/{token}`, `/v1/ad-revenue`, `/v1/push-token`, `/v1/links/resolve`.
- Entitlement 200s are ECDSA P-256 signed (`Revnix-Signed-At`, `Revnix-Signature`); the SDK pins public keys and only trusts a cache that verifies. Unsigned 200s are returned but not cached. Transient failures serve the cache flagged `stale`; 401/403/404/409 always throw; `Retry-After` honored.
- Events: in-memory queue, cap 1000, batch 100, flush at 20; persisted at most once per second and on background. Failed purchase registrations persist keyed `source:token:transactionId`, drained by `retryPendingPurchases()`.
- SKAN conversion values go to Apple only. Route or payload change here = matching change in `revnix-app/convex` HTTP routes + `/docs/ios`.

## Tests (`Tests/RevnixTests/`)
XCTest; network stubbed with `URLProtocol` (`config.session`), clock injected (`config.now`). `RevnixClientTests` is the big one; others per area (Tracking, Attribution, Skan, DeepLinkPrivacy, ImplicitPlacement, Preview, Paywall*, StoreKitIntegration via `Revnix.storekit` which skips without `SKTestSession`, PrivacyManifest).

## Commands
- `swift test` is the only build/test command (CI and release run exactly this). No lint or format config, no xcodebuild anywhere.
- `scripts/release.sh --bump auto|major|minor|patch [--version x.y.z] [--dry-run]` is what CI runs; locally only `--dry-run`.
- On this Mac `swift`, `xcodebuild` and `/usr/bin/git` are blocked by the Xcode license prompt (`sudo xcodebuild -license`). CI is the practical test runner. Read-only git: `/Applications/GitHub Desktop.app/Contents/Resources/app/git/bin/git`.

## Git, CI, release
- `.github/workflows/ci.yml`: PRs to `main` + manual; `macos-15`, `xcode-select` Xcode_16, `swift test`, 30 min timeout.
- `.github/workflows/release.yml`: manual dispatch (inputs bump, version, app_sha, run_key), dispatched by `../revnix-app/.github/workflows/release-sdks.yml` (job `revnix-ios`) on app releases. Steps: `swift test` on main, skip if only `.github`/`*.md` changed, release.sh bump (CHANGELOG + podspec + `sdkVersion`), PR `release/vX.Y.Z` merged with `--merge`, annotated tag `vX.Y.Z`, `gh release create`.
- Never hand-bump versions or push tags. Every user-visible change gets a bullet under `## Unreleased` in `CHANGELOG.md` (`### Breaking` → major, `### Added` → minor, else patch).
- Merge commits only into `main` (ruleset; `gh pr merge --merge`, squash is refused). Opposite of revnix-app, which squash-merges into `dev`. No direct pushes to `main`.

## Conventions
- Actor + `Sendable` throughout; callbacks are `@Sendable`. New public API stays `Sendable` and `#if canImport`-guarded for platforms without the framework (watchOS has no ATT).
- Customer ids are percent-encoded exactly once when building paths.
