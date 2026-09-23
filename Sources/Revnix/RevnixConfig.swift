import Foundation

public struct RevnixDiagnostic: Sendable {
    public let op: String
    public let message: String
}

/// REV-299: how confidently `/v1/installs` matched the deferred link to this
/// install. iOS never reports `exact` — there is no install-time signal that
/// certain, only fingerprint matching against a click seen shortly before.
public enum DeferredDeepLinkMatch: String, Sendable, Decodable {
    case exact
    case probabilistic
}

/// The most recent deep link this device received. See
/// `RevnixClient.lastDeepLink()`.
public struct LastDeepLink: Sendable, Equatable {
    public let url: URL
    public let receivedAt: Date
}

/// AT11: the install-attribution verdict for a customer. See
/// `RevnixClient.getAttribution()`. The server's `installMatch: "unknown"`
/// (no install recorded yet, a normal cold-start race) never reaches a host
/// as a verdict: `getAttribution()` returns nil and `onAttribution` does not
/// fire, so there is one "no attribution yet" representation, not two.
public struct RevnixAttribution: Codable, Equatable, Sendable {
    /// `referrer`, `click`, `impression` or `organic`.
    public let installMatch: String
    /// Unix ms.
    public let attributedAt: Int
    /// Unix ms — set when the customer was later re-attributed.
    public let reattributedAt: Int?
    public let linkToken: String?
    public let referrerSource: String?
    public let matchSignals: [String]?
    public let source: String?
    public let medium: String?
    public let campaign: String?
    public let term: String?
    public let content: String?
}

public struct RevnixConfig: Sendable {
    /// Publishable key (`rvx_pk_live_…` / `rvx_pk_test_…`). The key fixes
    /// app + environment server-side. Secret keys never ship in a binary —
    /// identify/alias are server-proxied by design.
    public var apiKey: String
    /// e.g. `https://your-deployment.convex.site`
    public var baseURL: URL
    public var storage: RevnixStorage
    /// Per-request timeout. Default 10 s (matches revnix-react).
    public var timeout: TimeInterval
    /// Snapshots older than this serve as all-inactive. Default 14 days.
    public var offlineMaxCacheAge: TimeInterval
    /// Soft TTL on entitlement reads: a snapshot this fresh answers without a
    /// network round trip, so a screen full of gates costs one fetch. Default
    /// 30 s; set 0 to always fetch.
    public var entitlementsTTL: TimeInterval
    /// Read-your-writes poll schedule after a purchase, in seconds. Each delay
    /// is jittered ±20% so a promo push doesn't put a fleet's polls in
    /// lockstep against our own rate limiter. Empty disables polling.
    public var readYourWritesDelays: [TimeInterval]
    /// Swallowed background failures report here (queue drains, telemetry).
    public var onDiagnostic: (@Sendable (RevnixDiagnostic) -> Void)?
    /// Injectable clock for tests.
    public var now: @Sendable () -> Date
    /// Injectable session for tests (URLProtocol stubs).
    public var session: URLSession?
    /// REV-268: facts about the device, sent with every placement resolve so
    /// targeting rules can be evaluated on the request that serves the
    /// paywall, and stored on the customer as reserved `device.*` attributes.
    /// Defaults to `DeviceFacts.detect()`; adjust the fields you know better
    /// (an app that reads its own version from elsewhere), or pass `nil` to
    /// send nothing.
    public var device: DeviceFacts?
    /// REV-272: called when one of the six implicit moments resolved to a
    /// paywall — an app launch, a session start, a deep link, a dismissed
    /// paywall, an abandoned checkout, or the install itself. Present it
    /// however your app presents paywalls; the SDK deliberately does not
    /// present for you, because it does not own your navigation stack and a
    /// paywall pushed over a launch screen is worse than no paywall.
    ///
    /// Providing this handler is what TURNS IMPLICIT PLACEMENTS ON. Without
    /// it the SDK makes no extra requests, except `handleDeepLink`, which
    /// always reports the link it is handed so its `link.*` attribution
    /// facts land on the customer. With the handler set, the SDK also asks
    /// `GET /v1/config` once and fires for the other moments this app has
    /// actually configured in the dashboard.
    ///
    /// ⚠️ Pass `trigger.resolution.placementKey` to `logPaywallDisplay` for the
    /// display you present. That is what tells the SDK this display came FROM
    /// an implicit trigger, and it is the only thing that stops a
    /// `paywall_decline` paywall from firing `paywall_decline` again when the
    /// customer dismisses it — a loop with no way out but force-quitting. The
    /// server refuses to serve back the very same paywall as a backstop, but it
    /// cannot see a rule pointing at a DIFFERENT paywall that points back.
    public var onImplicitPaywall: (@Sendable (RevnixImplicitTrigger) -> Void)?
    /// REV-272: explicit off switch, even when `onImplicitPaywall` is set.
    /// `nil` means "on when a handler is present". Set `false` and
    /// `handleDeepLink` still reports the link it is handed, for its
    /// `link.*` attribution facts only — it never presents a deep-link
    /// paywall. A dashboard preview link (`?revnix_preview=<token>`) is the
    /// exception and still presents.
    public var implicitPlacements: Bool?
    /// REV-299: called with the link the user clicked before installing,
    /// echoed back by `/v1/installs` at most once per install — never fires
    /// again on later launches, even for later install reports. Route it
    /// yourself (and, if it should also gate an implicit `deeplink_open`
    /// paywall rule, hand the URL to `handleDeepLink`).
    public var onDeferredDeepLink: (@Sendable (URL, DeferredDeepLinkMatch) -> Void)?
    /// AT11: called on the main actor whenever the install-attribution
    /// verdict CHANGES — an Apple Search Ads token resolving or a
    /// re-attribution genuinely changes the answer, so this can fire more
    /// than once across a session, and never fires twice for the same
    /// verdict. Fired after `registerInstall(platform:appVersion:)`'s report
    /// resolves and again after the Search Ads attribution token is
    /// reported; `getAttribution()` gives the same answer on demand.
    ///
    /// Setting this handler is what turns the automatic refresh on: without
    /// it the SDK never asks for the verdict on its own.
    public var onAttribution: (@Sendable (RevnixAttribution) -> Void)?
    /// REV-272: the rule the client reads — `implicitPlacements` when set,
    /// else whether a handler is present.
    public var implicitPlacementsEnabled: Bool {
        implicitPlacements ?? (onImplicitPaywall != nil)
    }
    /// REV-272: how the SDK learns the app came to the foreground —
    /// `session_start` is built on it. Defaults to UIKit's
    /// `didBecomeActiveNotification`; use `.disabled` to opt out.
    public var lifecycle: RevnixAppLifecycle
    /// REV-272: how long the app must have been backgrounded for the return
    /// to count as a new session rather than an app switch. Default 30 min.
    public var sessionTimeout: TimeInterval
    /// SKAdNetwork, on by default: `registerInstall` registers the app for
    /// attribution once per install, which is what makes Apple generate the
    /// install postback at all. Set `false` to opt out entirely — the SDK then
    /// neither registers the app nor forwards `updateSkanConversionValue`
    /// calls to Apple.
    public var skan: Bool

    public init(
        apiKey: String,
        baseURL: URL,
        storage: RevnixStorage? = nil,
        timeout: TimeInterval = 10,
        offlineMaxCacheAge: TimeInterval = 14 * 24 * 3600,
        entitlementsTTL: TimeInterval = 30,
        readYourWritesDelays: [TimeInterval] = [0.25, 0.5, 1, 2],
        onDiagnostic: (@Sendable (RevnixDiagnostic) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        session: URLSession? = nil,
        device: DeviceFacts? = DeviceFacts.detect(),
        onImplicitPaywall: (@Sendable (RevnixImplicitTrigger) -> Void)? = nil,
        implicitPlacements: Bool? = nil,
        onDeferredDeepLink: (@Sendable (URL, DeferredDeepLinkMatch) -> Void)? = nil,
        onAttribution: (@Sendable (RevnixAttribution) -> Void)? = nil,
        lifecycle: RevnixAppLifecycle = .system,
        sessionTimeout: TimeInterval = revnixDefaultSessionTimeout,
        skan: Bool = true
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.storage = storage ?? FileStorage()
        self.timeout = timeout
        self.offlineMaxCacheAge = offlineMaxCacheAge
        self.entitlementsTTL = entitlementsTTL
        self.readYourWritesDelays = readYourWritesDelays
        self.onDiagnostic = onDiagnostic
        self.now = now
        self.session = session
        self.device = device
        self.onImplicitPaywall = onImplicitPaywall
        self.implicitPlacements = implicitPlacements
        self.onDeferredDeepLink = onDeferredDeepLink
        self.onAttribution = onAttribution
        self.lifecycle = lifecycle
        self.sessionTimeout = sessionTimeout
        self.skan = skan
    }
}
