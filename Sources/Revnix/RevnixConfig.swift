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
        device: DeviceFacts? = DeviceFacts.detect()
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
    }
}
