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

Swift Package Manager. In Xcode: **File → Add Package Dependencies…**, paste
`https://github.com/Oth-tech/RevnixSDK-iOS.git`, and pick the `Revnix`
library. Or in `Package.swift`:

```swift
.package(url: "https://github.com/Oth-tech/RevnixSDK-iOS.git", from: "1.4.2")
```

Releases are the `vX.Y.Z` tags on this repository. CocoaPods is not
published (its trunk is going read-only).

## Quick start

```swift
import Revnix

let client = RevnixClient(RevnixConfig(
    apiKey: "rvx_pk_live_…",
    baseURL: URL(string: "https://your-deployment.convex.site")!
))

// Every resolvePlacement carries the device facts (platform, OS/app version,
// locale, currency, App Store storefront, model, install date, sandbox, first
// open). RevnixConfig(device:) defaults to DeviceFacts.detect(); pass nil to
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
| `client.logPaywallDisplay(placementKey:paywallId:) async -> String?` | The same beacon, but it returns the `viewId` it minted. Use it whenever you intend to report the close or an interaction: that id is what pairs the halves of one display. |
| `client.logPaywallClosed(viewId:placementKey:paywallId:) async` | Ends the display `logPaywallDisplay` opened. Idempotent per view id, so a retry or a double-dismiss cannot count two. Without it a funnel knows how many saw the paywall, not how many left without buying. |
| `client.logPaywallEvent(_:viewId:…) async` | One of the six interactions (`.selected`, `.purchaseStarted`, `.purchaseAbandoned`, `.purchaseFailed`, `.restore`, `.error`), i.e. what happened BETWEEN the display and the close. `RevnixPaywallView` sends all but the purchase outcome, which only your app can see. All six are pure history: over-reporting skews a report, it never grants or revokes access. |
| `client.logAdRevenue(revenue:currency:network:mediation:adUnit:placement:format:eventId:) async` | Fire-and-forget impression-level ad revenue from a mediation SDK's paid callback (AdMob `paidEventHandler`, AppLovin MAX `didPayRevenue(for:)`). Non-finite or <= 0 revenue sends nothing. Pass `eventId` to make retries idempotent. Appends `ad.revenue`, which feeds only the ROAS table. |
| `client.track(_:properties:eventId:) async` | Fire-and-forget custom in-app event. `event` must match `^[a-z0-9_]{1,64}$` (invalid names send nothing) and lands as `custom.<event>`. `properties` is a flat `[String: JSONValue]` of `.string`, `.number` or `.bool`. Not for purchases: those stay on `registerPurchase`. |
| `client.setAttribution(provider:network:campaign:adGroup:creative:) async` | Fire-and-forget forward of an MMP's attribution callback so Revnix credits revenue to the right network/campaign. Call it from Adjust's attribution callback (`provider: "adjust", network: attribution.network, campaign: attribution.campaign, adGroup: attribution.adgroup, creative: attribution.creative`) or AppsFlyer's `onConversionDataSuccess` (`provider: "appsflyer", network: data["media_source"], campaign: data["campaign"], adGroup: data["af_adset"], creative: data["af_ad"]`, skip when `data["af_status"] == "Organic"`). |
| `client.setPushToken(_:) async` (`String` or `Data`) | Register this device's push token for uninstall measurement: a daily silent push probes it, and when APNs reports it dead the customer gets `app.uninstalled`. Fire-and-forget, dedupes per customer+token. Call from `didRegisterForRemoteNotificationsWithDeviceToken` (the `Data` overload hex-encodes for you). |
| `client.requestTrackingAuthorization() async -> Int` | Shows Apple's App Tracking Transparency prompt and returns its answer (`0` notDetermined, `1` restricted, `2` denied, `3` authorized, `-1` where ATT doesn't exist). Stores `att_status` and `idfa` (when authorized) as customer attributes; needs `NSUserTrackingUsageDescription` in Info.plist and an active app. Never throws. |
| `RevnixClient.setLocale(_ tag: String?)` (static) | Forces every designed paywall rendered after the call into `tag`'s language, regardless of the device's; `nil` clears it. A view's own `locale:` still wins for that one view. |
| `client.pendingPurchaseCount() -> Int` | Size of the persistent purchase-registration retry queue. |
| `client.handleDeepLink(_:) async` | Hand over the URL that opened the app (`onOpenURL`, which covers the launch URL too). The one implicit moment the SDK cannot see itself; an ordinary link is always reported so its `link.*` attribution facts land on the customer, and it presents a paywall only when implicit placements are on AND `deeplink_open` is configured, but a dashboard QR/link preview is always handed to `onImplicitPaywall`. |
| `client.lastDeepLink() -> LastDeepLink?` | The most recent link this device received: an ordinary `handleDeepLink` call or a delivered deferred deep link, whichever was last. Persisted across launches and logout; `nil` when none has been recorded. Dashboard preview links are never recorded. |
| `client.getAttribution() async -> RevnixAttribution?` | The install-attribution verdict for this customer: `installMatch` plus the campaign fields that apply. `nil` when none has been recorded yet (a normal cold-start race) or the read failed. Never throws; fetched fresh on every call. Pass `onAttribution` to be told when it changes instead. |
| `client.start() async` / `client.stop()` | Implicit placements start automatically from `init` when `onImplicitPaywall` is set and stop in `deinit`; the pair is public for hosts driving their own lifecycle. `stop()` also halts `handleDeepLink`'s reporting, and `start()` resumes it, even with no handler set. |
| `RevnixError` | What every throwing client call throws. `isRetryable` splits transient cases (`.network`, `.timeout`, `.rateLimited(retryAfterMs:)`, `.server`, `.badResponse`) from deliberate ones (`.auth`, `.notFound`, `.purchaseBlocked`, `.invalid`). A 409 surfaces as `.purchaseBlocked`, including a resolve before anything is published. |

### Custom events

Report any in-app moment that isn't a paywall interaction or a purchase, e.g.
`level_up` or `onboarding_complete`:

```swift
await client.track("level_up", properties: ["level": .number(5), "premium": .bool(true)])
```

### Implicit placements

Six placements resolve without a `resolvePlacement` call: `app_install`,
`app_launch`, `session_start`, `deeplink_open`, `paywall_decline` and
`transaction_abandon`. Passing `onImplicitPaywall` to `RevnixConfig` turns
them on (off by default: no handler, no extra requests for the other five
moments, though `handleDeepLink` always reports the link it is handed); the
SDK then asks `GET /v1/config` once and fires only for the moments the
dashboard configured. `implicitPlacements = false` is an explicit off switch
for paywalls, but it does not stop `handleDeepLink`'s report.
The handler runs on the main actor, so present directly. When you present,
pass `placementKey: trigger.resolution.placementKey` to `RevnixPaywallView`;
that marks the display as implicit and is what stops a `paywall_decline`
paywall from firing `paywall_decline` again. A close is a decline: never
report one for a display that ended in a purchase.

The dashboard's QR/link paywall preview rides the same `handleDeepLink` call:
a scanned or tapped preview link (`<scheme>://revnix-preview?revnix_preview=…`)
is fetched and handed to `onImplicitPaywall` regardless of dashboard
configuration. Detect it from the trigger's resolution
(`resolution.placementKey == revnixPreviewPlacementKey` or
`resolution.preview == true`) before presenting; `RevnixPaywallView` already
disables purchases and analytics on it (a host rendering its own UI must
check itself).

### Deep links

SwiftUI: `.onOpenURL` already covers cold start, nothing else to wire:

```swift
.onOpenURL { url in Task { await client.handleDeepLink(url) } }
```

UIKit with a `SceneDelegate`: the launch URL arrives in `willConnectTo`,
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
for the link's click window (one hour by default, configurable per link up to 24 hours). `registerInstall(platform:appVersion:)` (leave `platform`
`nil` and it reports the platform for you) can come back with the link that install
matched: probabilistic, from a same-network click inside that window, so it can
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

An email service provider (Mailchimp, SendGrid, …) rewrites a link through
its own click-tracking domain before the customer ever sees it. Pass one of
those through `resolveDeepLink(_:)` to get the app's own link back before
routing and handing it to `handleDeepLink`:

```swift
let unwrapped = await client.resolveDeepLink(url)
router.open(unwrapped)
Task { await client.handleDeepLink(unwrapped) }
```

Never throws. A lookup failure, an input over 1024 characters, or an input
that is not already an `http`/`https` URL returns the input unchanged with no
request sent. The result can still be an http(s) URL when the chain could not
be unwrapped, so check its scheme before routing.

### Apple Search Ads attribution

`registerInstall` also mints the AdServices attribution token (iOS only, no
credentials or dashboard setup) and posts it to the server, which asks Apple
whether the install came from a Search Ads campaign. Zero host code beyond
the `registerInstall` call you already make; it retries on every cold start,
inside the same 24-hour window the server accepts, until Apple gives a
definitive answer.

### SKAdNetwork

`registerInstall` also registers the app for SKAdNetwork attribution, once per
install. Apple generates no install postback at all until an app makes that
call. Report a conversion value whenever your funnel reaches a milestone worth
measuring:

```swift
await client.updateSkanConversionValue(12, coarse: .high, lockWindow: false)
```

The fine value is 0…63; anything outside that range is refused without calling
Apple. `coarse`/`lockWindow` need iOS 16.1; below that only the fine value is
sent. Values go to Apple only, never to Revnix. Opt out entirely with
`RevnixConfig(skan: false)`: the SDK then neither registers the app nor
forwards these calls.

Your app must also add `NSAdvertisingAttributionReportEndpoint` to its
`Info.plist`, or Apple never delivers your copy of
the winning postback. The value is the bare apex and identical for every
Revnix customer, because Apple keeps only the registrable part of the domain:
a subdomain or a path is dropped:

```xml
<key>NSAdvertisingAttributionReportEndpoint</key>
<string>https://revnix.io</string>
```

Apple then POSTs to
`https://revnix.io/.well-known/skadnetwork/report-attribution/`.

### Last deep link

`client.lastDeepLink() -> LastDeepLink?` returns the most recent link this
device received (`{ url, receivedAt }`), so an app that swallowed a link
during login/onboarding can ask for it again later:

```swift
if let last = await client.lastDeepLink() {
    router.open(last.url)
}
```

It is updated by `handleDeepLink` (ordinary links only, not dashboard
previews) and by a delivered deferred deep link. Persisted, and not cleared
by `logout()`.

### Install attribution

`client.getAttribution() async -> RevnixAttribution?` answers which campaign, link
or referrer this install was credited to (`installMatch` is `referrer`,
`click`, `impression` or `organic`, plus `attributedAt` and whichever of
`linkToken`, `referrerSource`, `matchSignals`, `source`, `medium`,
`campaign`, `term`, `content` apply). `nil` means no verdict yet (a normal
race on the first cold start) or a failed read, reported to `onDiagnostic`.
Never throws.

Pass `onAttribution` to be told when the verdict CHANGES instead of polling.
A Search Ads token resolving or a re-attribution changes it, so it can fire
more than once, but never twice for the same verdict:

```swift
let client = RevnixClient(RevnixConfig(
    apiKey: "rvx_pk_live_…",
    baseURL: URL(string: "https://your-deployment.convex.site")!,
    onAttribution: { attribution in analytics.setCampaign(attribution.campaign) }
))
```

The handler runs on the main actor. Setting it is what turns the automatic
refresh on: the SDK then asks for the verdict after `registerInstall`'s
report and after the Search Ads token is reported, and makes no extra request
at all without it.

### Uninstall measurement

Revnix measures uninstalls the way Adjust/AppsFlyer do: register the
device's push token, and once a day a silent push probes it; when APNs
reports the token dead, the customer gets an `app.uninstalled` event. Call
it from the push-registration delegate:

```swift
func application(_ application: UIApplication,
                  didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { await client.setPushToken(deviceToken) }
}
```

A `String` overload is also available for a token you already hex-encoded
yourself. Fire-and-forget, like the other beacons: never throws, dedupes
per customer+token. Requires the app's Push Notifications + Background
Modes → Remote notifications capability; no notification permission
needed, the probe is silent. See
[Uninstall measurement](https://revnix.io/docs/uninstall-measurement).

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
| `onDeferredDeepLink` | `nil` | Deferred link from `registerInstall`'s response, at most once per install, on the main actor. |
| `onAttribution` | `nil` | Verdict-change callback; setting it turns on the automatic refresh. |
| `lifecycle` | `.system` | Foreground/background source for `session_start` (`didBecomeActive` / `didEnterBackground`); `.disabled` keeps launch-time moments only. |
| `sessionTimeout` | `30 * 60` s | How long the app must be backgrounded for the return to count as a session. |
| `skan` | `true` | SKAdNetwork registration once per install; `false` opts out and stops forwarding `updateSkanConversionValue`. |
| `attWaitTimeout` | `nil` | Holds the first `registerInstall` report up to this many seconds while App Tracking Transparency is still undetermined, so the install carries the IDFA. `nil` never waits. |
| `deviceIntegrity` | `false` | Attaches Apple App Attest evidence to install-related requests. See [Device integrity](#device-integrity). |
| `now` / `session` | n/a | Injectable clock and `URLSession` for tests. |

### Device integrity

Set `deviceIntegrity: true` to attach Apple App Attest evidence (a key id
and attestation blob) to every install-related request, so Revnix's server
can verify the install came from the genuine app on a genuine Apple device.
The same evidence is minted once per customer id per launch and rides `registerInstall`,
the Apple Search Ads attribution post and `setAttribution`; the server
verifies it once per install and keeps that verdict. Omitted silently wherever App Attest isn't
available (Simulator, older OS). Never fails or skips any of those requests,
though the first one on a fresh install may wait up to 10s for the
attestation call to Apple before giving up and sending without it.

Development-signed builds attest against Apple's development environment;
TestFlight and App Store builds use production. No extra setup is needed on
the app side. To turn on verification server-side, set your Apple Team ID
in Revnix **Settings → App stores** and enable **Require device integrity**
in **Settings → Fraud prevention**.

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

`waitForEntitlements(seq:)` reads entitlements (the first read may come from
the soft TTL snapshot); the polls after that first read bypass the soft TTL
(the point of a poll is a fresh ledger cursor), and resolve with the last
read rather than throwing if the ledger never catches up.

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
