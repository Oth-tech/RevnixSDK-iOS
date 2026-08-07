# Revnix Swift SDK

Native Swift SDK for [Revnix](https://revnix.com) — StoreKit 2 purchase glue plus
the same resilience policy as `revnix-react`.

- **StoreKit 2 native.** One call from tap to unlocked gate, with the JWS as
  server-verifiable proof — claims are never provisional.
- **Offline-correct by design.** A network blip keeps paying customers unlocked;
  a revoked key still locks them out. Those are different cases and the SDK
  treats them differently.
- **One fetch per screen.** A soft TTL plus in-flight coalescing means a screen
  full of gates costs a single request.

Requires iOS 16+ / macOS 13+ / tvOS 16+ / watchOS 9+ and Swift 5.9.

## Install

**Swift Package Manager**

```swift
.package(url: "https://github.com/Oth-tech/revnix-swift.git", from: "0.1.0")
```

**CocoaPods**

```ruby
pod 'Revnix', '~> 0.1'
```

## Quick start

```swift
import Revnix

let client = RevnixClient(RevnixConfig(
    apiKey: "rvx_pk_live_…",
    baseURL: URL(string: "https://your-deployment.convex.site")!
))

// At app launch: replay store transactions + drain the offline queue.
let observer = RevnixStoreKit.startObserving(client: client)
await client.retryPendingPurchases()
await client.registerInstall(platform: "ios")

// Purchase → registered with JWS proof → gate unlocked (read-your-writes).
if let result = try await RevnixStoreKit.purchase(product, client: client) {
    _ = try await client.waitForEntitlements(seq: result.seq)
}

// Gate. Never throws; unknown/unreachable = locked.
if await client.isEntitled("pro") { /* … */ }
```

Use the **publishable** key (`rvx_pk_…`) only. Secret keys must never ship in a
binary, so `identify`/`alias` are deliberately not SDK methods — proxy them from
your server (see the docs recipe).

## Resilience policy

This is a product contract, not an implementation detail. `revnix-react`'s
`resilience.test.ts` is the spec; every case there is ported to
`Tests/RevnixTests/RevnixClientTests.swift`, and both must stay in agreement.

| Behavior | Rule |
|---|---|
| Entitlement reads | Network-first |
| Transient failure (offline, timeout, 429, 5xx, non-JSON 200) | Serve cache, `stale = true` |
| Deliberate rejection (401/403/404/409) | **Always throw** — a cache must never defeat a kill-switch |
| Cached entitlement past `expiresAt` | Grace 3 days, then inactive (covers a renewal an offline device cannot see) |
| Cache age ceiling | 14 days → all inactive |
| Clock rolled back > 5 min | All inactive |
| Repeat reads | 30 s soft TTL + in-flight coalescing |
| Failed purchase registration | Persistent queue keyed `source:token:transactionId`, retryable failures only |
| Retry / poll delays | ±20% jitter; `Retry-After` honored when the server sends it |
| Swallowed background failures | `onDiagnostic` callback; count rides `X-Revnix-Bg-Failures` |

`waitForEntitlements(seq:)` bypasses the soft TTL — the point of that poll is a
fresh ledger cursor — and resolves with the last read rather than throwing if
the ledger never catches up.

## Tests

```sh
swift test
```

27 unit tests cover the full resilience matrix against a `URLProtocol` stub.

The four store-glue tests in `StoreKitIntegrationTests` drive a real StoreKit 2
purchase through `SKTestSession` against `Tests/RevnixTests/Resources/Revnix.storekit`.
StoreKit resolves products against a **host application bundle**, which a
headless `swift test` process does not have, so they skip there with an
explanatory message. Run them from Xcode against a simulator target to exercise
the full purchase → register → unlock path.

## Not in v1

- Paywall UI rendering — `resolvePlacement` ships the config, your app renders it.
- `identify` / `alias` — server-proxied by design (see above).
- Amazon and other stores.
