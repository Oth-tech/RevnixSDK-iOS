import Foundation

/// Core client — a faithful port of revnix-react's resilience policy
/// (revnix-sdk `resilience.test.ts` is the behavioral spec):
/// - entitlements are network-first; TRANSIENT failures serve the cache
///   flagged `stale`, DELIBERATE rejections (401/403/404/409) always throw;
/// - cached entitlements past expiry by >3 days serve inactive; snapshots
///   older than `offlineMaxCacheAge` (14 d) or behind a >5 min clock
///   rollback serve all-inactive;
/// - a 30 s soft TTL plus in-flight coalescing keeps a screen of gates to
///   one fetch;
/// - failed purchase registrations persist to a retry queue keyed
///   `source:token:transactionId` and drain idempotently (the server dedupes
///   on the shared purchaseKey).
public actor RevnixClient {
    /// `nonisolated` so the synchronous render-diagnostic hook can reach the
    /// host's sink without hopping onto the actor: RevnixConfig is Sendable
    /// and this is a `let`, so there is nothing here to race on.
    private nonisolated let config: RevnixConfig
    private let session: URLSession

    private static let expiryGraceMs = 3 * 24 * 3600 * 1000
    private static let rollbackToleranceMs = 5 * 60 * 1000
    private static let cacheCustomers = 4

    private var inflightEntitlements: Task<CustomerEntitlements, Error>?
    private var bgFailures = 0

    public init(_ config: RevnixConfig) {
        self.config = config
        if let injected = config.session {
            self.session = injected
        } else {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = config.timeout
            self.session = URLSession(configuration: c)
        }
    }

    // MARK: - Identity

    public func customerId() -> String {
        if let existing = config.storage.get(Keys.customerId) { return existing }
        let minted = generateAnonymousId()
        config.storage.set(Keys.customerId, minted)
        return minted
    }

    /// Fresh anonymous identity. Per-customer caches age out via LRU.
    public func logout() -> String {
        let minted = generateAnonymousId()
        config.storage.set(Keys.customerId, minted)
        return minted
    }

    // MARK: - Entitlements

    public func entitlements() async throws -> CustomerEntitlements {
        let cid = customerId()
        let nowMs = nowMs()
        let rolledBack = updateWallClock(nowMs: nowMs)

        // Soft TTL: a live snapshot this fresh is authoritative. A TTL of 0
        // disables the shortcut entirely (always-fetch).
        let ttlMs = Int(config.entitlementsTTL * 1000)
        if ttlMs > 0, let entry = cacheEntry(for: cid),
            nowMs - entry.fetchedAt <= ttlMs, !rolledBack
        {
            var fresh = entry.snapshot
            fresh.stale = false
            fresh.fetchedAt = entry.fetchedAt
            return fresh
        }

        if let inflight = inflightEntitlements {
            return try await inflight.value
        }
        let task = Task<CustomerEntitlements, Error> {
            try await self.fetchEntitlements(cid: cid, nowMs: nowMs, rolledBack: rolledBack)
        }
        inflightEntitlements = task
        defer { inflightEntitlements = nil }
        return try await task.value
    }

    /// Network-only read — no TTL shortcut, no cache fallback. Throws on any
    /// failure. The read-your-writes poll needs a genuinely fresh cursor.
    private func fetchFreshEntitlements(
        cid: String, nowMs: Int
    ) async throws -> CustomerEntitlements {
        let data = try await request(
            path: "/v1/customers/\(encode(cid))/entitlements", method: "GET")
        var snapshot = try decode(CustomerEntitlements.self, from: data)
        snapshot.stale = false
        snapshot.fetchedAt = nowMs
        storeCacheEntry(CacheEntry(snapshot: snapshot, fetchedAt: nowMs), for: cid)
        return snapshot
    }

    private func fetchEntitlements(
        cid: String, nowMs: Int, rolledBack: Bool
    ) async throws -> CustomerEntitlements {
        do {
            return try await fetchFreshEntitlements(cid: cid, nowMs: nowMs)
        } catch let err as RevnixError where err.isRetryable {
            // Transient — the cache answers, under the offline policy.
            guard let entry = cacheEntry(for: cid) else { throw err }
            return applyOfflinePolicy(entry, nowMs: nowMs, rolledBack: rolledBack)
        }
        // Deliberate rejections fall through and throw: a kill-switch must
        // not be defeated by the cache.
    }

    /// Last cached snapshot with the offline policy applied; nil when the
    /// customer has never had a live read.
    public func cachedEntitlements() -> CustomerEntitlements? {
        let cid = customerId()
        let nowMs = nowMs()
        guard let entry = cacheEntry(for: cid) else { return nil }
        return applyOfflinePolicy(entry, nowMs: nowMs, rolledBack: updateWallClock(nowMs: nowMs))
    }

    /// Gate helper — never throws; unknown/unreachable = locked.
    public func isEntitled(_ entitlementId: String) async -> Bool {
        let snapshot: CustomerEntitlements?
        do {
            snapshot = try await entitlements()
        } catch {
            snapshot = cachedEntitlements()
        }
        return snapshot?.entitlements.contains {
            $0.entitlementId == entitlementId && $0.isActive
        } ?? false
    }

    /// Read-your-writes: poll entitlements until the response's ledger cursor
    /// is at least `seq`, then return it. Resolves with the LAST read if the
    /// schedule runs out or reads only come from the stale cache — it never
    /// spins forever and never throws a timeout, so a slow ledger degrades to
    /// "not unlocked yet" rather than an error the app has to handle.
    public func waitForEntitlements(seq: Int) async throws -> CustomerEntitlements {
        let cid = customerId()
        var last = try await entitlements()
        for delay in config.readYourWritesDelays {
            if last.stale != true && last.cursor >= seq { return last }
            // ±20% jitter: promo pushes synchronize a fleet's purchases, and
            // identical schedules keep every device's poll in lockstep
            // against our own rate limiter.
            try await sleep(jittered(delay))
            do {
                // TTL-bypassing: the point of this poll is a FRESH cursor, so
                // the soft TTL must not answer it from the last snapshot.
                last = try await fetchFreshEntitlements(cid: cid, nowMs: nowMs())
            } catch let err as RevnixError {
                // The server said exactly how long to back off — honor it
                // instead of fighting our own rate limiter.
                if let retryAfterMs = err.retryAfterMs, retryAfterMs > 0 {
                    try await sleep(TimeInterval(retryAfterMs) / 1000)
                }
                // Transient failure: keep the last read, let the schedule run.
            }
        }
        return last
    }

    /// ±20% jitter around a delay.
    private func jittered(_ seconds: TimeInterval) -> TimeInterval {
        seconds * (0.8 + Double.random(in: 0..<1) * 0.4)
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func applyOfflinePolicy(
        _ entry: CacheEntry, nowMs: Int, rolledBack: Bool
    ) -> CustomerEntitlements {
        var snapshot = entry.snapshot
        let tooOld = nowMs - entry.fetchedAt > Int(config.offlineMaxCacheAge * 1000)
        if tooOld || rolledBack {
            snapshot = CustomerEntitlements(
                customerId: snapshot.customerId, cursor: snapshot.cursor,
                entitlements: snapshot.entitlements.map { $0.inactive() },
                stale: true, fetchedAt: entry.fetchedAt)
        } else {
            snapshot = CustomerEntitlements(
                customerId: snapshot.customerId, cursor: snapshot.cursor,
                entitlements: snapshot.entitlements.map { ent in
                    if ent.isActive, let expiresAt = ent.expiresAt,
                        nowMs > expiresAt + Self.expiryGraceMs
                    {
                        return ent.inactive()
                    }
                    return ent
                },
                stale: true, fetchedAt: entry.fetchedAt)
        }
        return snapshot
    }

    // MARK: - Purchases

    @discardableResult
    public func registerPurchase(
        _ input: RegisterPurchaseInput
    ) async throws -> RegisterPurchaseResult {
        let cid = customerId()
        do {
            let result = try await postPurchase(input, customerId: cid)
            if result.customerId != cid {
                // Identity resolution merged us — adopt the canonical id.
                config.storage.set(Keys.customerId, result.customerId)
            }
            removeQueued(key: queueKey(input))
            return result
        } catch let err as RevnixError where err.isRetryable {
            enqueue(input)
            throw err
        }
    }

    /// Drain the persisted queue. Safe to call on every launch/foreground —
    /// the server dedupes on the shared purchaseKey.
    @discardableResult
    public func retryPendingPurchases() async -> Int {
        let cid = customerId()
        var delivered = 0
        for item in queuedItems() {
            do {
                _ = try await postPurchase(item.input, customerId: cid)
                removeQueued(key: item.key)
                delivered += 1
            } catch let err as RevnixError where !err.isRetryable {
                // The server refused on purpose — retrying forever is noise.
                removeQueued(key: item.key)
                diagnostic(op: "retryPendingPurchases", message: "dropped \(item.key): \(err)")
            } catch {
                bgFailures += 1
                diagnostic(op: "retryPendingPurchases", message: "kept \(item.key): \(error)")
            }
        }
        return delivered
    }

    public func pendingPurchaseCount() -> Int { queuedItems().count }

    private func postPurchase(
        _ input: RegisterPurchaseInput, customerId cid: String
    ) async throws -> RegisterPurchaseResult {
        var body: [String: JSONValue] = [
            "customerId": .string(cid),
            "source": .string(input.source.rawValue),
            "token": .string(input.token),
            "productId": .string(input.productId),
            "transactionId": .string(input.transactionId),
        ]
        if let v = input.occurredAt { body["occurredAt"] = .number(Double(v)) }
        if let v = input.expiresAt { body["expiresAt"] = .number(Double(v)) }
        if let v = input.signedTransactionInfo {
            body["signedTransactionInfo"] = .string(v)
        }
        if let v = input.rawPayload { body["rawPayload"] = v }
        let data = try await request(path: "/v1/purchases", method: "POST", body: body)
        return try decode(RegisterPurchaseResult.self, from: data)
    }

    // MARK: - Placements & telemetry

    public func resolvePlacement(_ key: String) async throws -> PlacementResolution {
        do {
            // REV-219: the customer id lets the server pin a sticky experiment
            // variant; older servers simply ignore the parameter.
            let data = try await request(
                path: "/v1/placements/\(encode(key))/offering", method: "GET",
                query: [URLQueryItem(name: "customer", value: customerId())])
            let resolution = try decode(PlacementResolution.self, from: data)
            if let encoded = try? String(
                data: JSONEncoder().encode(resolution), encoding: .utf8)
            {
                config.storage.set(Keys.placement(key), encoded)
            }
            return resolution
        } catch let err as RevnixError where err.isRetryable {
            guard let cached = config.storage.get(Keys.placement(key)),
                let data = cached.data(using: .utf8),
                let resolution = try? JSONDecoder().decode(
                    PlacementResolution.self, from: data)
            else { throw err }
            return resolution
        }
    }

    /// Fire-and-forget install beacon; once per customer id.
    public func registerInstall(
        platform: String? = nil, appVersion: String? = nil
    ) async {
        let cid = customerId()
        guard config.storage.get(Keys.installReported(cid)) == nil else { return }
        var body: [String: JSONValue] = [
            "customerId": .string(cid),
            "sdkVersion": .string(Self.sdkVersion),
        ]
        if let v = platform { body["platform"] = .string(v) }
        if let v = appVersion { body["appVersion"] = .string(v) }
        do {
            _ = try await request(path: "/v1/installs", method: "POST", body: body)
            config.storage.set(Keys.installReported(cid), "1")
        } catch {
            bgFailures += 1
            diagnostic(op: "registerInstall", message: "\(error)")
        }
    }

    /// Fire-and-forget impression beacon (feeds funnels + view conversions).
    public func logPaywallShown(placementKey: String?, paywallId: String?) async {
        _ = await logPaywallDisplay(placementKey: placementKey, paywallId: paywallId)
    }

    /// The same beacon, returning the view id it generated (REV-252).
    ///
    /// Hand that id to `logPaywallClosed` when the customer dismisses THIS
    /// display: the two events sharing one view id is what lets the ledger
    /// pair a close with the display it ended, and the gap between their
    /// timestamps is the customer's dwell on the screen. The id is returned
    /// even when delivery fails — the caller's pairing must not depend on the
    /// network, and the close beacon retries on its own key.
    ///
    /// Optional only to satisfy `RevnixPaywallViewReporting`, whose default
    /// implementation has to be able to say "this reporter cannot pair".
    /// RevnixClient always returns an id.
    @discardableResult
    public func logPaywallDisplay(placementKey: String?, paywallId: String?) async -> String? {
        let viewId = UUID().uuidString.lowercased()
        var body: [String: JSONValue] = [
            "customerId": .string(customerId()),
            "viewId": .string(viewId),
            "sdkVersion": .string(Self.sdkVersion),
        ]
        if let v = placementKey { body["placementKey"] = .string(v) }
        if let v = paywallId { body["paywallId"] = .string(v) }
        do {
            _ = try await request(path: "/v1/paywalls/viewed", method: "POST", body: body)
        } catch {
            bgFailures += 1
            diagnostic(op: "logPaywallShown", message: "\(error)")
        }
        return viewId
    }

    /// Fire-and-forget dismissal beacon (REV-252) — the other half of a
    /// display's life. Idempotent per view id, exactly like the view report.
    ///
    /// Pass the id `logPaywallDisplay` returned for this display.
    public func logPaywallClosed(viewId: String, placementKey: String?, paywallId: String?) async {
        var body: [String: JSONValue] = [
            "customerId": .string(customerId()),
            "viewId": .string(viewId),
            "sdkVersion": .string(Self.sdkVersion),
        ]
        if let v = placementKey { body["placementKey"] = .string(v) }
        if let v = paywallId { body["paywallId"] = .string(v) }
        do {
            _ = try await request(path: "/v1/paywalls/closed", method: "POST", body: body)
        } catch {
            bgFailures += 1
            diagnostic(op: "logPaywallClosed", message: "\(error)")
        }
    }

    /// Set attributes on the current customer (REV-033 v2). Attributes are
    /// what A/B-test audiences target — set `country`, `app_version`,
    /// `locale`, or any custom key you want to segment on. A `.null` value
    /// deletes the key.
    ///
    /// Throws, unlike the fire-and-forget beacons: the next placement resolve
    /// may depend on these, so a silent failure would look like broken
    /// targeting. `email` and `username` are reserved (secret key only), and
    /// an attribute your backend already set cannot be changed from a device.
    public func setAttributes(_ attributes: [String: JSONValue]) async throws {
        _ = try await request(
            path: "/v1/customers/\(encode(customerId()))/attributes",
            method: "POST",
            body: ["attributes": .object(attributes)])
    }

    // MARK: - Transport

    public static let sdkVersion = "0.2.0"

    private func request(
        path: String, method: String, query: [URLQueryItem]? = nil,
        body: [String: JSONValue]? = nil
    ) async throws -> Data {
        var url = config.baseURL.appendingPathComponent(path)
        if let query,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        {
            components.queryItems = query
            url = components.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = config.timeout
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("revnix-swift/\(Self.sdkVersion)", forHTTPHeaderField: "X-Revnix-SDK")
        if bgFailures > 0 {
            // Server-visible client pain with zero app wiring.
            req.setValue(String(bgFailures), forHTTPHeaderField: "X-Revnix-Bg-Failures")
            bgFailures = 0
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let err as URLError where err.code == .timedOut {
            throw RevnixError.timeout
        } catch {
            throw RevnixError.network(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw RevnixError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message =
                (try? JSONDecoder().decode([String: String].self, from: data))?[
                    "error"] ?? ""
            throw RevnixError.fromHTTP(
                status: http.statusCode, message: message,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // A 200 that is not our JSON = captive portal / interception —
            // retryable, so callers fall back to cache instead of unlocking
            // nothing forever.
            throw RevnixError.badResponse
        }
    }

    // MARK: - Cache plumbing

    private struct CacheEntry: Codable {
        let snapshot: CustomerEntitlements
        let fetchedAt: Int
    }

    private struct QueuedPurchase: Codable {
        let key: String
        let source: String
        let token: String
        let productId: String
        let transactionId: String
        let occurredAt: Int?
        let expiresAt: Int?
        let signedTransactionInfo: String?
        let rawPayload: JSONValue?

        var input: RegisterPurchaseInput {
            RegisterPurchaseInput(
                source: RevnixStore(rawValue: source) ?? .apple, token: token,
                productId: productId, transactionId: transactionId,
                occurredAt: occurredAt, expiresAt: expiresAt,
                signedTransactionInfo: signedTransactionInfo,
                rawPayload: rawPayload)
        }
    }

    private enum Keys {
        static let customerId = "revnix.customerId"
        static let wallClock = "revnix.lastWallClock"
        static let queue = "revnix.pendingPurchases"
        static let cacheIndex = "revnix.entIndex"
        static func cache(_ cid: String) -> String { "revnix.ent.\(cid)" }
        static func placement(_ key: String) -> String { "revnix.placement.\(key)" }
        static func installReported(_ cid: String) -> String {
            "revnix.installReported.\(cid)"
        }
    }

    private func nowMs() -> Int { Int(config.now().timeIntervalSince1970 * 1000) }

    /// Persist the high-water wall clock; report whether the clock has been
    /// rolled back past tolerance (defeats "set the clock back to stay
    /// subscribed offline").
    private func updateWallClock(nowMs: Int) -> Bool {
        let stored = config.storage.get(Keys.wallClock).flatMap(Int.init) ?? 0
        if nowMs > stored { config.storage.set(Keys.wallClock, String(nowMs)) }
        return nowMs + Self.rollbackToleranceMs < stored
    }

    private func cacheEntry(for cid: String) -> CacheEntry? {
        guard let raw = config.storage.get(Keys.cache(cid)),
            let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: data)
    }

    private func storeCacheEntry(_ entry: CacheEntry, for cid: String) {
        if let data = try? JSONEncoder().encode(entry),
            let raw = String(data: data, encoding: .utf8)
        {
            config.storage.set(Keys.cache(cid), raw)
        }
        // LRU over recent customers so a shared device can't grow unbounded.
        var index =
            config.storage.get(Keys.cacheIndex)
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
            ?? []
        index.removeAll { $0 == cid }
        index.insert(cid, at: 0)
        while index.count > Self.cacheCustomers {
            config.storage.remove(Keys.cache(index.removeLast()))
        }
        if let data = try? JSONEncoder().encode(index),
            let raw = String(data: data, encoding: .utf8)
        {
            config.storage.set(Keys.cacheIndex, raw)
        }
    }

    private func queueKey(_ input: RegisterPurchaseInput) -> String {
        "\(input.source.rawValue):\(input.token):\(input.transactionId)"
    }

    private func queuedItems() -> [QueuedPurchase] {
        config.storage.get(Keys.queue)
            .flatMap {
                try? JSONDecoder().decode([QueuedPurchase].self, from: Data($0.utf8))
            } ?? []
    }

    private func persistQueue(_ items: [QueuedPurchase]) {
        if let data = try? JSONEncoder().encode(items),
            let raw = String(data: data, encoding: .utf8)
        {
            config.storage.set(Keys.queue, raw)
        }
    }

    private func enqueue(_ input: RegisterPurchaseInput) {
        var items = queuedItems()
        let key = queueKey(input)
        guard !items.contains(where: { $0.key == key }) else { return }
        items.append(
            QueuedPurchase(
                key: key, source: input.source.rawValue, token: input.token,
                productId: input.productId, transactionId: input.transactionId,
                occurredAt: input.occurredAt, expiresAt: input.expiresAt,
                signedTransactionInfo: input.signedTransactionInfo,
                rawPayload: input.rawPayload))
        persistQueue(items)
    }

    private func removeQueued(key: String) {
        let items = queuedItems().filter { $0.key != key }
        persistQueue(items)
    }

    private nonisolated func diagnostic(op: String, message: String) {
        config.onDiagnostic?(RevnixDiagnostic(op: op, message: message))
    }

    /// A block paywall reporting a paint string it could not read. Routed to
    /// the same sink as every other swallowed failure, so a host that already
    /// wired `onDiagnostic` needs no new wiring to see render fallbacks.
    public nonisolated func reportRenderDiagnostic(_ message: String) {
        diagnostic(op: "paywall.render", message: message)
    }

    private func encode(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? segment
    }
}
