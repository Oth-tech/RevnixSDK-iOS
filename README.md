# Revnix Swift SDK

Native Swift SDK for [Revnix](https://revnix.io), StoreKit 2 purchase glue plus
the same resilience policy as `revnix-react`.

- **StoreKit 2 native.** One call from tap to unlocked gate, with the JWS as
  server-verifiable proof: claims are never provisional.
- **Offline-correct by design.** A network blip keeps paying customers unlocked;
  a revoked key still locks them out. Those are different cases and the SDK
  treats them differently.
- **One fetch per screen.** A soft TTL plus in-flight coalescing means a screen
  full of gates costs a single request.

Requires iOS 16+ / macOS 13+ / tvOS 16+ / watchOS 9+ and Swift 5.9.

## Install

> Neither coordinate below resolves yet; see
> [Distribution status](#distribution-status).

**Swift Package Manager**

```swift
.package(url: "https://github.com/Oth-tech/RevnixSDK-iOS.git", from: "0.3.0")
```

**CocoaPods**

```ruby
pod 'Revnix', '~> 0.3'
```

## Quick start

```swift
import Revnix

let client = RevnixClient(RevnixConfig(
    apiKey: "rvx_pk_live_…",
    baseURL: URL(string: "https://your-deployment.convex.site")!
))

// Every resolvePlacement carries the device facts (platform, OS/app version,
// locale, currency, App Store storefront, model, install date, sandbox, first
// open) — RevnixConfig(device:) defaults to DeviceFacts.detect(); pass nil to
// send nothing. Targeting rules use them from the first launch.

// At app launch: replay store transactions + drain the offline queue.
let observer = RevnixStoreKit.startObserving(client: client)
await client.retryPendingPurchases()
await client.registerInstall(platform: "ios")

// Purchase → registered with JWS proof → gate unlocked (read-your-writes).
if let result = try await RevnixStoreKit.purchase(product, client: client) {
    _ = try await client.waitForEntitlements(seq: result.seq)
}

// Gate. Never throws; a transient failure answers from the cache; a deliberate rejection or no cache = locked.
if await client.isEntitled("pro") { /* … */ }
```

Use the **publishable** key (`rvx_pk_…`) only. Secret keys must never ship in a
binary, so `identify`/`alias` are deliberately not SDK methods; proxy them from
your server (see the docs recipe).

## Paywalls and A/B tests

`resolvePlacement` returns the published offering plus a **typed**
`PaywallConfig`: nine layouts in `template`: `focus`, `feature-list`,
`minimal`, `hero`, `timeline`, `plans`, `feature-grid`, `offer`, `reveal`, a
light/dark `mode`, and optional `review` (stars, quote, author, count) and
`offer` (anchor price, urgency line) blocks. `template` stays a `String` on
purpose so a config published with a future layout still decodes instead of
failing the whole resolve. Your app draws it; prices still come from StoreKit,
so the display can never disagree with the charge.

The resolve sends the customer id, so a running A/B test serves that
customer's variant. The `offering` and `paywall` you get back are *already*
the variant's; render them as-is. `experiment` is attribution metadata, and
is `nil` when no running test covers the placement:

```swift
let resolution = try await client.resolvePlacement("paywall_main")
if let experiment = resolution.experiment {
    analytics.log("paywall_shown", [
        "experiment": experiment.key,
        "variant": experiment.variantId,
    ])
}
```

Assignment is sticky per customer and survives identity merges.

### Targeting: `setAttributes`

A test can be narrowed to an audience: conditions over customer attributes.
`setAttributes` supplies the facts those conditions read, which for a
mobile-only app is the only place they exist:

```swift
try await client.setAttributes([
    "country": .string("US"),
    "app_version": .string("4.2.0"),
    "stale_key": .null,          // null deletes the key
])
```

This awaits the write rather than firing and forgetting, because the next
`resolvePlacement` may depend on it. Set an audience's attributes *before* the
first resolve on a covered placement; eligibility is checked at that resolve.
`email` and `username` are reserved (secret key, from your server), and an
attribute your backend already set cannot be changed from a device; both
reject the whole batch rather than applying part of it.

## Paywall UI

`RevnixPaywallView` renders the resolved config as SwiftUI (all nine layouts,
light/dark mode, accent, badge, social proof, offer anchors), in lockstep with
the dashboard's paywall-builder preview and the React Native renderer. You
supply the titles and localized prices from StoreKit, so the display never
disagrees with the charge:

```swift
let resolution = try await client.resolvePlacement("paywall_main")
if let paywall = resolution.paywall {
    RevnixPaywallView(
        config: paywall.config,
        packages: products.map { product in
            RevnixPaywallPackage(
                packageId: packageId(for: product),
                title: product.displayName,
                priceLabel: product.displayPrice)
        },
        onPurchase: { packageId in /* RevnixStoreKit.purchase(…) */ },
        loading: purchasing,
        onRestore: { Task { await RevnixStoreKit.restore(client: client) } },
        client: client,          // reports one paywall.viewed per appearance
        placementKey: "paywall_main",
        paywallId: paywall.paywallId
    )
}
```

Selection is internal by default (initially the config's highlight package)
or controlled via `selectedPackageId`/`onSelectPackage`; `theme:` takes a
partial `RevnixPaywallTheme.Override` on top of the config's mode; footer
links follow `config.footer`; explicit `onTerms`/`onPrivacy` handlers win
over configured URLs, which otherwise open via the environment's `openURL`.
An unrecognized future `template` renders the classic layout rather than
nothing, and a struck-through anchor price is dropped whenever its currency
symbol disagrees with the store's localized price.

When `config.blocks` carries a design from the paywall builder, the view
renders that design instead of the `template` layout, in the language `locale:`
names (default: the device's). `onClose:` makes the paywall dismissible (the
design's own close, or a drawn one when it has none) and, with `client:`,
reports `paywall.closed`; your app performs the dismissal, and without it no
close is drawn.

## API surface

Beyond the calls shown above:

| API | What it does |
|---|---|
| `client.entitlements() async throws -> CustomerEntitlements` | Network-first entitlement read under the resilience policy below; a snapshot served from the cache has `stale == true`. |
| `client.registerPurchase(_:) async throws -> RegisterPurchaseResult` | Registers a `RegisterPurchaseInput` for a purchase your own StoreKit code made. Retryable failures are queued and rethrown. `RevnixStoreKit.purchase` returns `nil` instead of throwing when registration fails. |
| `RevnixStoreKit.restore(client:) async -> Int` | Re-registers everything in `Transaction.currentEntitlements` (wire it to a "Restore purchases" button). The server dedupes on the shared purchase key, so it is always safe; returns the number registered. |
| `client.customerId() -> String` | Current customer id; an `rvx_anon_…` id is minted (and persisted) on first call. |
| `client.logout() -> String` | Mints a fresh anonymous customer locally and returns it. Call at sign-out, or the next user inherits the previous one's cached entitlements. |
| `client.cachedEntitlements() -> CustomerEntitlements?` | Last cached snapshot with the offline policy applied, no network; `nil` when the customer has never had a live read. |
| `client.logPaywallShown(placementKey:paywallId:) async` | Fire-and-forget impression beacon (feeds funnels and view conversions); failures go to `onDiagnostic`, never thrown. |
| `client.logPaywallDisplay(placementKey:paywallId:) async -> String?` | The same beacon, but it returns the `viewId` it minted. Use it whenever you intend to report the close or an interaction — that id is what pairs the halves of one display. |
| `client.logPaywallClosed(viewId:placementKey:paywallId:) async` | Ends the display `logPaywallDisplay` opened. Idempotent per view id, so a retry or a double-dismiss cannot count two. Without it a funnel knows how many saw the paywall, not how many left without buying. |
| `client.logPaywallEvent(_:viewId:…) async` | One of the six interactions — `.selected`, `.purchaseStarted`, `.purchaseAbandoned`, `.purchaseFailed`, `.restore`, `.error` — i.e. what happened BETWEEN the display and the close. `RevnixPaywallView` sends all but the purchase outcome, which only your app can see. All six are pure history: over-reporting skews a report, it never grants or revokes access. |
| `client.pendingPurchaseCount() -> Int` | Size of the persistent purchase-registration retry queue. |
| `client.handleDeepLink(_:) async` | Hand over the URL that opened the app (`onOpenURL`, which covers the launch URL too). The one implicit moment the SDK cannot see itself; an ordinary link is always reported so its `link.*` attribution facts land on the customer, and it presents a paywall only when implicit placements are on AND `deeplink_open` is configured, but a dashboard QR/link preview is always handed to `onImplicitPaywall`. |
| `client.start() / stop() async` | Implicit placements start automatically from `init` when `onImplicitPaywall` is set and stop in `deinit`; the pair is public for hosts driving their own lifecycle. `stop()` also halts `handleDeepLink`'s reporting, and `start()` resumes it, even with no handler set. |
| `RevnixError` | What every throwing client call throws. `isRetryable` splits transient cases (`.network`, `.timeout`, `.rateLimited(retryAfterMs:)`, `.server`, `.badResponse`) from deliberate ones (`.auth`, `.notFound`, `.purchaseBlocked`, `.invalid`). A 409 surfaces as `.purchaseBlocked`, including a resolve before anything is published. |

### Implicit placements

Six placements resolve without a `resolvePlacement` call: `app_install`,
`app_launch`, `session_start`, `deeplink_open`, `paywall_decline` and
`transaction_abandon`. Passing `onImplicitPaywall` to `RevnixConfig` turns
them on (off by default — no handler, no extra requests for the other five
moments, though `handleDeepLink` always reports the link it is handed); the
SDK then asks `GET /v1/config` once and fires only for the moments the
dashboard configured. `implicitPlacements = false` is an explicit off switch
for paywalls, but it does not stop `handleDeepLink`'s report.
The handler runs on the main actor, so present directly. When you present,
pass `placementKey: trigger.resolution.placementKey` to `RevnixPaywallView`
— that marks the display as implicit and is what stops a `paywall_decline`
paywall from firing `paywall_decline` again. A close is a decline: never
report one for a display that ended in a purchase.

The dashboard's QR/link paywall preview rides the same `handleDeepLink` call:
a scanned or tapped preview link (`<scheme>://revnix-preview?revnix_preview=…`)
is fetched and handed to `onImplicitPaywall` regardless of dashboard
configuration. Detect it from the trigger's resolution —
`resolution.placementKey == revnixPreviewPlacementKey` or
`resolution.preview == true` — before presenting; `RevnixPaywallView` already
disables purchases and analytics on it (a host rendering its own UI must
check itself).

### Deep links

SwiftUI — `.onOpenURL` already covers cold start, nothing else to wire:

```swift
.onOpenURL { url in Task { await client.handleDeepLink(url) } }
```

UIKit with a `SceneDelegate` — the launch URL arrives in `willConnectTo`,
not in the warm callbacks:

```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
           options connectionOptions: UIScene.ConnectionOptions) {
    if let url = connectionOptions.urlContexts.first?.url
        ?? connectionOptions.userActivities.first?.webpageURL {
        Task { await client.handleDeepLink(url) }
    }
}

func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if let url = URLContexts.first?.url { Task { await client.handleDeepLink(url) } }
}

func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if let url = userActivity.webpageURL { Task { await client.handleDeepLink(url) } }
}
```

`urlContexts` is a custom scheme, `userActivities` a universal link (both
cold start); `openURLContexts` / `continue` are the same two while running.
Each callback sees a given open once, so no double-report guard is needed.

### Deferred deep links

A click on a Revnix link sends iOS to the App Store, remembering the click
for up to an hour. `registerInstall(platform:appVersion:)` — leave `platform`
`nil` and it reports the platform for you — can come back with the link that install
matched: probabilistic, from a same-network click within that hour, so it can
be wrong on a shared network. Only a link whose scheme matches the app's
configured URL scheme is ever returned. Pass `onDeferredDeepLink` to get it,
delivered at most once per install, on the main actor:

```swift
let client = RevnixClient(RevnixConfig(
    apiKey: "rvx_pk_live_…",
    baseURL: URL(string: "https://your-deployment.convex.site")!,
    onDeferredDeepLink: { url, match in router.open(url) }
))
await client.registerInstall()
```

Route the URL yourself; optionally also pass it to `handleDeepLink` for
`deeplink_open` paywall rules.

### `RevnixConfig` knobs

Everything but `apiKey` and `baseURL` has a default:

| Knob | Default | What it does |
|---|---|---|
| `storage` | `FileStorage()` | Persistence adapter (`RevnixStorage` protocol). `FileStorage` writes to Application Support; `MemoryStorage` is provided for tests / ephemeral use. |
| `timeout` | `10` s | Per-request timeout. |
| `offlineMaxCacheAge` | 14 days | Cache-served snapshots older than this serve every entitlement as inactive. |
| `entitlementsTTL` | `30` s | Soft TTL on entitlement reads: a snapshot this fresh answers without a network round trip. `0` restores always-fetch. |
| `readYourWritesDelays` | `[0.25, 0.5, 1, 2]` | Post-purchase entitlement poll schedule in seconds, jittered ±20%; empty disables polling. |
| `onDiagnostic` | n/a | Callback for swallowed background failures. |
| `device` | `DeviceFacts.detect()` | Device facts sent in the `X-Revnix-Device` header on every placement resolve; `nil` sends nothing. |
| `onImplicitPaywall` | `nil` | The on-switch for implicit placements; called on the main actor with `RevnixImplicitTrigger { placement, resolution }`. |
| `implicitPlacements` | `nil` | Explicit override of "on when a handler is present". `false` stops implicit paywalls, not `handleDeepLink`'s report. |
| `lifecycle` | `.system` | Foreground/background source for `session_start` (`didBecomeActive` / `didEnterBackground`); `.disabled` keeps launch-time moments only. |
| `sessionTimeout` | `30 * 60` s | How long the app must be backgrounded for the return to count as a session. |
| `now` / `session` | n/a | Injectable clock and `URLSession` for tests. |

## Resilience policy

This is a product contract, not an implementation detail. `revnix-react`'s
`resilience.test.ts` is the spec; every case there is ported to
`Tests/RevnixTests/RevnixClientTests.swift`, and both must stay in agreement.

| Behavior | Rule |
|---|---|
| Entitlement reads | Network-first |
| Transient failure (offline, timeout, 429, 5xx, non-JSON 200) | Serve cache, `stale = true` |
| Deliberate rejection (401/403/404/409) | **Always throw**: a cache must never defeat a kill-switch |
| Cached entitlement past `expiresAt` | Grace 3 days, then inactive (covers a renewal an offline device cannot see) |
| Cache age ceiling | 14 days → all inactive |
| Clock rolled back > 5 min | All inactive |
| Repeat reads | 30 s soft TTL + in-flight coalescing |
| Failed purchase registration | Persistent queue keyed `source:token:transactionId`, retryable failures only |
| Retry / poll delays | ±20% jitter; `Retry-After` honored when the server sends it |
| Swallowed background failures | `onDiagnostic` callback; count rides `X-Revnix-Bg-Failures` |

`waitForEntitlements(seq:)` bypasses the soft TTL (the point of that poll is a
fresh ledger cursor), and resolves with the last read rather than throwing if
the ledger never catches up.

## Tests

```sh
swift test
```

The unit tests in `RevnixClientTests` cover the full resilience matrix against a `URLProtocol` stub.

The four store-glue tests in `StoreKitIntegrationTests` drive a real StoreKit 2
purchase through `SKTestSession` against `Tests/RevnixTests/Resources/Revnix.storekit`.
StoreKit resolves products against a **host application bundle**, which a
headless `swift test` process does not have, so they skip there with an
explanatory message. Run them from Xcode against a simulator target to exercise
the full purchase → register → unlock path.

## Not in v1

- `identify` / `alias`: server-proxied by design (see above).
- Amazon and other stores.

## Distribution status

**Not yet published.** The Swift Package Manager and CocoaPods coordinates
above are the intended ones, but neither the repository nor the pod is public
yet, so `swift package resolve` / `pod install` will not find them. Until they
ship, apps integrate over the [REST API](https://revnix.io/docs/rest-api), the
same `/v1` contract this SDK speaks, so migrating later does not change the
backend integration.
