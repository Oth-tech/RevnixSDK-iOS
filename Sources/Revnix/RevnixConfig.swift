import Foundation

public struct RevnixDiagnostic: Sendable {
    public let op: String
    public let message: String
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
    /// it the SDK makes no extra requests at all. With it, the SDK asks
    /// `GET /v1/config` once and then fires only for the moments this app has
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
    /// `nil` means "on when a handler is present".
    public var implicitPlacements: Bool?
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
        lifecycle: RevnixAppLifecycle = .system,
        sessionTimeout: TimeInterval = revnixDefaultSessionTimeout
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
        self.lifecycle = lifecycle
        self.sessionTimeout = sessionTimeout
    }
}
