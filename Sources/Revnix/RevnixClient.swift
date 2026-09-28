import Foundation
#if canImport(StoreKit)
    import StoreKit
#endif
#if canImport(AdServices)
    import AdServices
#endif

typealias SkanUpdater = @Sendable (Int, RevnixCoarseValue?, Bool) async throws -> Void

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
    private static let serverReattributionWindowMs = 24 * 3600 * 1000

    private var inflightEntitlements: Task<CustomerEntitlements, Error>?
    private var bgFailures = 0
    /// REV-268: the encoded X-Revnix-Device value, built on the first resolve
    /// and kept for the client's lifetime (so `firstOpen` holds for the whole
    /// first session). `.some(nil)` = facts disabled or unencodable.
    private var deviceHeader: String??
    // REV-272: implicit placements. Off unless the host said what to do with a
    // paywall — without a handler there is nothing to do with the answer, and
    // firing anyway would spend requests and ledger rows on nobody's behalf.
    private var implicitEnabled: Bool { config.implicitPlacementsEnabled }
    /// Which of the six this app has configured. One in-flight task, coalesced;
    /// a SUCCESS is memoised for the client's lifetime (the task keeps its
    /// value), a FAILURE clears the field so the next moment asks again — an
    /// offline cold start must not disable every implicit moment until the
    /// next launch. `implicitConfigRetryAt` keeps that retry from happening on
    /// every paywall close of an offline session: one probe per minute.
    private var implicitConfigTask: Task<Set<String>, Error>?
    private var implicitConfigRetryAt: Date = .distantPast
    private var lifecycleCancel: (@Sendable () -> Void)?
    /// When the app last went to the BACKGROUND, or nil while it has not. A
    /// return after `config.sessionTimeout` away is a new session; sooner is
    /// an app switch. Measured from the background transition, not from the
    /// last return — the latter would mint a session after 35 minutes of
    /// continuous use plus a three-second switch.
    private var lastBackgroundAt: Date?
    /// LOOP GUARD: view ids of displays that came FROM an implicit trigger. A
    /// paywall shown because a paywall was dismissed must not itself fire
    /// `paywall_decline`, or the customer is handed the same screen forever.
    /// Never released — a double-tapped close reports two closes on one id,
    /// and releasing on the first would let the second re-enter the loop.
    /// Bounded by implicit displays per process: a handful of ids.
    private var implicitViewIds: Set<String> = []
    /// True once `start()` ran; `stop()` resets it so the pair is symmetric.
    private var implicitStarted = false
    /// Set by `stop()`. Checked after every suspension point on the implicit
    /// paths — a launch batch that was mid-flight when the client was retired
    /// must not hand a paywall to a host that has moved on.
    private var implicitStopped = false
    /// The cold-start batch while it runs, resolving to whether it presented.
    /// A deep link delivered on the first frame (SwiftUI's onOpenURL) waits
    /// for it, or the customer gets the launch paywall AND the link paywall.
    private var launchBatch: Task<Bool, Never>?
    /// True when `customerId()` minted the id on THIS launch — the install
    /// signal, the same one `/v1/installs` uses. In memory on purpose: a
    /// stored "seen this id" marker would fire `app_install` for the entire
    /// existing base on the first launch after an SDK upgrade, and again
    /// after every `logout()`.
    private var mintedThisLaunch = false
    var skanUpdater: SkanUpdater?
    private var skanUpdatesInFlight = 0
    private var skanRegisteredByHostUpdate = false

    public init(_ config: RevnixConfig) {
        self.config = config
        if let injected = config.session {
            self.session = injected
        } else {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = config.timeout
            self.session = URLSession(configuration: c)
        }
        if config.implicitPlacementsEnabled {
            // REV-272: kicked off rather than awaited — a launch must never
            // wait on /v1/config, and every implicit path is fire-and-forget
            // from here down. Weak, so a client the host discards right after
            // construction is not kept alive by its own launch work.
            Task { [weak self] in await self?.start() }
        }
    }

    deinit {
        // The NotificationCenter observers outlive the reference otherwise —
        // one dead pair per client a SwiftUI host rebuilt, forever.
        lifecycleCancel?()
    }

    // MARK: - Implicit placements (REV-272)

    /// Begin watching for the six implicit moments. Called automatically from
    /// `init` when implicit placements are on; idempotent, and `stop()` makes
    /// it callable again, so a host driving its own lifecycle can pair them.
    ///
    /// A cold start is always both a launch AND a session — an operator who
    /// configured only `session_start` still wants the first one — and it is
    /// an install too when this launch minted the customer id. The three run
    /// in order, most specific first, and only the first that resolves to a
    /// paywall is handed to the host. All are still REPORTED — a launch is a
    /// launch whether or not a paywall showed — but an app that configured
    /// all three must not have three paywalls pushed onto its first frame.
    public func start() async {
        implicitStopped = false
        guard implicitEnabled, !implicitStarted else { return }
        implicitStarted = true

        // Subscribed BEFORE the batch, which can take a full network timeout
        // when offline: a customer who backgrounds the app during that window
        // and comes back an hour later is a session, and missing the
        // background transition would lose it.
        lifecycleCancel = config.lifecycle.onStateChange { [weak self] state in
            guard let self else { return }
            Task { await self.appStateChanged(state) }
        }

        // `customerId()` is what sets mintedThisLaunch, so it runs first.
        _ = customerId()
        var moments: [RevnixImplicitPlacement] = []
        if mintedThisLaunch { moments.append(.appInstall) }
        moments.append(.appLaunch)
        moments.append(.sessionStart)

        let batch = Task<Bool, Never> { [weak self] in
            var presented = false
            for placement in moments {
                guard let self else { return presented }
                let shown = await self.fireImplicit(placement, present: !presented)
                presented = presented || shown
            }
            return presented
        }
        launchBatch = batch
        _ = await batch.value
        launchBatch = nil
    }

    /// Stop watching. A replaced client would otherwise keep a foreground
    /// observer alive and mint a session on every return alongside its
    /// successor. Anything mid-flight (the launch batch, a config read) is
    /// told to hand nothing over.
    public func stop() {
        implicitStopped = true
        implicitStarted = false
        lifecycleCancel?()
        lifecycleCancel = nil
        implicitConfigTask?.cancel()
        implicitConfigTask = nil
    }

    /// Hand the SDK the URL that opened your app, from wherever you already
    /// receive it (`onOpenURL`, `application(_:open:options:)`, your router).
    ///
    /// This is the one implicit moment the SDK cannot see for itself — the URL
    /// goes to your entry point, and an SDK intercepting it would be fighting
    /// your router. An ordinary link is always reported so its `link.*`
    /// attribution facts land on the customer; a paywall presents only when
    /// implicit placements are on AND `deeplink_open` is configured in the
    /// dashboard. A dashboard QR/link preview
    /// (`<scheme>://revnix-preview?revnix_preview=<token>`) is always handed
    /// to `onImplicitPaywall`, regardless of dashboard configuration.
    /// Delivered on the first frame, while the cold-start batch is still
    /// deciding what to show, both wait for the batch — an ordinary link
    /// presents only if the batch showed nothing (the moment is reported
    /// either way), a preview presents after it.
    public func handleDeepLink(_ url: URL) async {
        let raw = url.absoluteString
        if let token = Self.previewToken(in: raw) {
            await presentPreview(token)
            return
        }
        recordLastDeepLink(url)
        let extra: [String: JSONValue] = [
            "url": .string(String(raw.prefix(1024))),
        ]
        var present = true
        if let batch = launchBatch { present = !(await batch.value) }
        _ = await fireImplicit(.deeplinkOpen, extra: extra, present: present)
    }

    /// Unwrap a link an email service provider (Mailchimp, SendGrid, …)
    /// rewrote through its own click-tracking domain, e.g.
    /// `https://click.mailchimp.com/track/abc` back to
    /// `com.voigu.app://promo?utm_source=email&utm_campaign=summer50`. Route
    /// on the result and pass it to `handleDeepLink` as usual; a lookup
    /// failure — or an input the server would 400 on — hands the input URL
    /// straight back unchanged, so the result may still be an http(s) URL
    /// when the chain could not be unwrapped: check the scheme before
    /// routing.
    public func resolveDeepLink(_ url: URL) async -> URL {
        let raw = url.absoluteString
        guard raw.count <= 1024, let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return url }
        do {
            let data = try await request(
                path: "/v1/links/resolve", method: "GET",
                query: [URLQueryItem(name: "url", value: raw)])
            let body = try decode(ResolveDeepLinkResponse.self, from: data)
            return URL(string: body.url) ?? url
        } catch {
            bgFailures += 1
            diagnostic(op: "resolveDeepLink", message: "\(error)")
            return url
        }
    }

    private struct ResolveDeepLinkResponse: Decodable {
        let url: String
    }

    /// The most recent deep link this device received — an ordinary
    /// `handleDeepLink` call or a delivered deferred deep link, whichever was
    /// last — for asking again after the original delivery got swallowed
    /// (e.g. by login/onboarding). Dashboard preview links are never
    /// recorded. Persisted, so it survives relaunch and logout. Never throws;
    /// nil when nothing is stored or the stored value is malformed.
    public func lastDeepLink() -> LastDeepLink? {
        guard let raw = config.storage.get(Keys.lastDeepLink),
            let data = raw.data(using: .utf8),
            let stored = try? JSONDecoder().decode(StoredDeepLink.self, from: data),
            let url = URL(string: stored.url)
        else { return nil }
        return LastDeepLink(
            url: url, receivedAt: Date(timeIntervalSince1970: Double(stored.receivedAt) / 1000))
    }

    private struct StoredDeepLink: Codable {
        let url: String
        let receivedAt: Int
    }

    private func recordLastDeepLink(_ url: URL) {
        let stored = StoredDeepLink(url: url.absoluteString, receivedAt: nowMs())
        guard let data = try? JSONEncoder().encode(stored),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        config.storage.set(Keys.lastDeepLink, raw)
    }

    private static let previewTokenPattern = try! NSRegularExpression(
        pattern: "[?&]revnix_preview=([0-9a-f]{64})(?:[&#]|$)")

    private static func previewToken(in urlString: String) -> String? {
        let range = NSRange(urlString.startIndex..., in: urlString)
        guard let match = previewTokenPattern.firstMatch(in: urlString, range: range),
            let tokenRange = Range(match.range(at: 1), in: urlString)
        else { return nil }
        return String(urlString[tokenRange])
    }

    private func presentPreview(_ token: String) async {
        if let batch = launchBatch { _ = await batch.value }
        guard !implicitStopped else { return }
        guard let handler = config.onImplicitPaywall else {
            diagnostic(op: "preview", message: "no onImplicitPaywall handler configured")
            return
        }
        do {
            let data = try await request(
                path: "/v1/paywalls/preview/\(encode(token))", method: "GET")
            guard !implicitStopped else { return }
            let resolution = try decodePreviewResolution(from: data)
            let trigger = RevnixImplicitTrigger(placement: .deeplinkOpen, resolution: resolution)
            await MainActor.run { handler(trigger) }
        } catch {
            bgFailures += 1
            diagnostic(op: "preview", message: "\(error)")
        }
    }

    private func decodePreviewResolution(from data: Data) throws -> PlacementResolution {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw RevnixError.badResponse }
        if obj["status"] == nil { obj["status"] = "ok" }
        if obj["revision"] == nil || obj["revision"] is NSNull { obj["revision"] = 0 }
        if obj["offering"] == nil || obj["offering"] is NSNull {
            obj["offering"] = ["offeringId": "", "displayName": "", "packages": []]
        }
        let filled = try JSONSerialization.data(withJSONObject: obj)
        return try decode(PlacementResolution.self, from: filled)
    }

    private func appStateChanged(_ state: RevnixAppState) async {
        guard !implicitStopped else { return }
        switch state {
        case .background:
            // First report wins: a platform that repeats "background" must not
            // keep resetting the clock forward.
            if lastBackgroundAt == nil { lastBackgroundAt = config.now() }
        case .foreground:
            // A foreground with no background before it is the launch itself,
            // which the batch already counted — or a duplicate report.
            guard let since = lastBackgroundAt else { return }
            lastBackgroundAt = nil
            // An app switch is not a session.
            if config.now().timeIntervalSince(since) >= config.sessionTimeout {
                // A new session is also when the memoised config is re-asked:
                // the server promises an operator's change shows up within
                // ~30 s, and a process backgrounded for days would otherwise
                // keep firing a moment the operator turned off — or never
                // fire one they turned on — until the next cold start.
                implicitConfigTask = nil
                _ = await fireImplicit(.sessionStart)
            }
        }
    }

    /// Which of the six this app has configured. See `implicitConfigTask`.
    private func implicitConfig() async -> Set<String> {
        if implicitConfigTask == nil, config.now() < implicitConfigRetryAt {
            // Inside the hold after a failure: answer "none" without a request.
            return []
        }
        let task = implicitConfigTask ?? Task { [self] in
            // The id does not change the answer — this route is
            // customer-independent — it only picks the server's rate-limit
            // bucket, so one busy app cannot 429 its own fleet off the feature.
            let data = try await request(
                path: "/v1/config", method: "GET",
                query: [URLQueryItem(name: "customer", value: customerId())])
            let body = try decode(ImplicitConfigResponse.self, from: data)
            return Set(body.implicitPlacements ?? [])
        }
        implicitConfigTask = task
        do {
            return try await task.value
        } catch {
            if implicitConfigTask == task { implicitConfigTask = nil }
            implicitConfigRetryAt = config.now().addingTimeInterval(Self.implicitConfigRetryHold)
            bgFailures += 1
            diagnostic(op: "implicitConfig", message: "\(error)")
            return []
        }
    }

    private static let implicitConfigRetryHold: TimeInterval = 60

    /// Report one implicit moment and present whatever it resolves to. Returns
    /// true when a paywall was handed to the host. `present` false still
    /// reports the moment (its ledger event is a fact either way) but hands
    /// nothing over — how the launch batch keeps a cold start to ONE paywall.
    /// Never throws: this runs on a launch and on every return to the
    /// foreground, so it must not throw into the host.
    @discardableResult
    private func fireImplicit(
        _ placement: RevnixImplicitPlacement,
        extra: [String: JSONValue] = [:],
        present: Bool = true
    ) async -> Bool {
        guard !implicitStopped else { return false }
        let resolve =
            implicitEnabled ? await implicitConfig().contains(placement.rawValue) : false
        guard resolve || placement == .deeplinkOpen, !implicitStopped else { return false }

        var body: [String: JSONValue] = [
            "customerId": .string(customerId()),
            "placement": .string(placement.rawValue),
            // One id per occurrence: retries of the same launch are absorbed,
            // a genuine second launch counts separately. Required server-side
            // for the three moments that append an event.
            "occurrenceId": .string(UUID().uuidString.lowercased()),
            "occurredAt": .number(Double(nowMs())),
            "sdkVersion": .string(Self.sdkVersion),
        ]
        if !resolve { body["resolve"] = .bool(false) }
        for (k, v) in extra { body[k] = v }
        do {
            let data = try await request(
                path: "/v1/placements/triggered", method: "POST", body: body,
                headers: await deviceHeaders())
            // The route's own body shape, decoded ONCE: the resolve fields are
            // optional because an unconfigured moment answers 200 with
            // `paywall: null` and no `status`/`revision` at all — a normal
            // state, not a decode failure to count against the server.
            let response = try decode(ImplicitTriggerResponse.self, from: data)
            guard !implicitStopped, present, resolve,
                let resolution = response.resolution, resolution.paywall != nil
            else { return false }
            let trigger = RevnixImplicitTrigger(placement: placement, resolution: resolution)
            // Presenting is UI. The host's handler runs on the main actor so a
            // `UIViewController.present` or a `@Published` write inside it is
            // not a background-thread crash.
            if let handler = config.onImplicitPaywall {
                await MainActor.run { handler(trigger) }
            }
            return true
        } catch {
            bgFailures += 1
            diagnostic(op: "implicit:\(placement.rawValue)", message: "\(error)")
            return false
        }
    }

    /// The two moments that happen ON a paywall, with the loop guard applied.
    /// `fromPaywallId` travels so the server can refuse to hand back the very
    /// paywall being dismissed.
    private func fireImplicitFromPaywall(
        _ placement: RevnixImplicitPlacement, viewId: String, paywallId: String?
    ) async {
        guard implicitEnabled else { return }
        // One hop, never a chain: this display was itself implicit.
        if implicitViewIds.contains(viewId) { return }
        var extra: [String: JSONValue] = ["fromViewId": .string(viewId)]
        if let v = paywallId { extra["fromPaywallId"] = .string(v) }
        _ = await fireImplicit(placement, extra: extra)
    }

    /// The `X-Revnix-Device` header for a request that resolves a placement —
    /// the resolve route and the implicit trigger route attach the same one,
    /// so a rule reading `device.appVersion` sees the same value either way.
    private func deviceHeaders() async -> [String: String] {
        guard let header = await currentDeviceHeader() else { return [:] }
        return ["X-Revnix-Device": header]
    }

    private struct ImplicitConfigResponse: Decodable {
        let implicitPlacements: [String]?
    }

    /// POST /v1/placements/triggered body: the resolve shape with every field
    /// optional, plus the two the route adds. `resolution` is non-nil only when
    /// the server actually resolved (status "ok" with an offering).
    private struct ImplicitTriggerResponse: Decodable {
        let skipReason: String?
        let recorded: Bool?
        let resolution: PlacementResolution?

        private enum CodingKeys: String, CodingKey {
            case skipReason, recorded, status
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            skipReason = try c.decodeIfPresent(String.self, forKey: .skipReason)
            recorded = try c.decodeIfPresent(Bool.self, forKey: .recorded)
            // Only a resolved answer carries `status`; the not_configured
            // branch omits it (and nulls revision/offering), so decoding the
            // strict model there would be the badResponse this avoids.
            if try c.decodeIfPresent(String.self, forKey: .status) == "ok" {
                resolution = try PlacementResolution(from: decoder)
            } else {
                resolution = nil
            }
        }
    }


    // MARK: - Identity

    public func customerId() -> String {
        if let existing = config.storage.get(Keys.customerId) { return existing }
        let minted = generateAnonymousId()
        config.storage.set(Keys.customerId, minted)
        // REV-272: the install signal. `logout()` below deliberately does not
        // set it — a new anonymous session is not a new install.
        mintedThisLaunch = true
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

    /// Gate helper: never throws. A transient failure answers from the offline cache; a deliberate rejection (401/403/404/409), an unknown id, or no cache answers false.
    public func isEntitled(_ entitlementId: String) async -> Bool {
        let snapshot: CustomerEntitlements?
        do {
            snapshot = try await entitlements()
        } catch {
            snapshot = nil
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
            // REV-268: the device facts ride along so targeting rules see THIS
            // device on THIS request, and the server stores them as
            // device.* attributes. Older servers ignore the header.
            let data = try await request(
                path: "/v1/placements/\(encode(key))/offering", method: "GET",
                query: [URLQueryItem(name: "customer", value: customerId())],
                headers: await deviceHeaders())
            let resolution = try decode(PlacementResolution.self, from: data)
            // Cache the wire bytes themselves (as revnix-kotlin does), not a
            // re-encode: offline then sees exactly the document the server
            // sent, including whatever this SDK version does not type.
            if let wire = String(data: data, encoding: .utf8) {
                config.storage.set(Keys.placement(key), wire)
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

    /// REV-268: assemble the device facts once. `installedAt` is the first
    /// launch this storage ever saw — written then, read back on every later
    /// one — and `firstOpen` is true for the whole of that first session. The
    /// storefront is asked of StoreKit once, unless the app set it.
    private func currentDeviceHeader() async -> String? {
        if let built = deviceHeader { return built }
        guard var facts = config.device else {
            deviceHeader = .some(nil)
            return nil
        }
        if facts.storefront == nil {
            facts.storefront = await Self.storefrontCountry()
        }
        let installedAt: Int
        let firstOpen: Bool
        if let stored = config.storage.get(Keys.installedAt).flatMap(Int.init), stored > 0 {
            installedAt = stored
            firstOpen = false
        } else {
            installedAt = nowMs()
            firstOpen = true
            config.storage.set(Keys.installedAt, String(installedAt))
        }
        let built = facts.encodedHeader(
            sdkVersion: Self.sdkVersion, installedAt: installedAt, firstOpen: firstOpen)
        deviceHeader = .some(built)
        return built
    }

    /// The App Store storefront's country (alpha-3), or nil where StoreKit
    /// has no store to ask — tests, or a process with no App Store account.
    private static func storefrontCountry() async -> String? {
        #if canImport(StoreKit)
            if #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) {
                return await Storefront.current?.countryCode
            }
        #endif
        return nil
    }

    /// Fire-and-forget install beacon; once per customer id.
    public func registerInstall(
        platform: String? = nil, appVersion: String? = nil
    ) async {
        defer {
            Task { [weak self] in await self?.collectAppleSearchAdsAttribution() }
            Task { [weak self] in await self?.armSkan() }
        }
        let cid = customerId()
        guard config.storage.get(Keys.installReported(cid)) == nil else { return }
        var body: [String: JSONValue] = [
            "customerId": .string(cid),
            "sdkVersion": .string(Self.sdkVersion),
        ]
        body["platform"] = .string(platform ?? DeviceFacts.platformName)
        if let v = appVersion { body["appVersion"] = .string(v) }
        do {
            let data = try await request(
                path: "/v1/installs", method: "POST", body: body, headers: await deviceHeaders())
            config.storage.set(Keys.installReported(cid), "1")
            refreshAttribution()
            await deliverDeferredDeepLink(from: data)
        } catch {
            bgFailures += 1
            diagnostic(op: "registerInstall", message: "\(error)")
        }
    }

    private func deliverDeferredDeepLink(from data: Data) async {
        guard config.storage.get(Keys.deferredDeepLinkDelivered) == nil else { return }
        config.storage.set(Keys.deferredDeepLinkDelivered, "1")
        guard let handler = config.onDeferredDeepLink,
            let response = try? JSONDecoder().decode(InstallResponse.self, from: data),
            let link = response.deferredDeepLink
        else { return }
        recordLastDeepLink(link.url)
        await MainActor.run { handler(link.url, link.match) }
    }

    private struct InstallResponse: Decodable {
        let deferredDeepLink: DeferredDeepLink?
        let appleAttribution: String?

        struct DeferredDeepLink: Decodable {
            let url: URL
            let match: DeferredDeepLinkMatch
        }
    }

    /// Mints the AdServices attribution token and hands it to the server,
    /// which posts it on to Apple to learn the Search Ads campaign (if any).
    /// Fire-and-forget, latched per customer id.
    public func collectAppleSearchAdsAttribution() async {
        await collectAppleSearchAdsAttribution(tokenOverride: nil)
    }

    /// `tokenOverride` is internal on purpose: the tests need a seam because
    /// the Simulator cannot mint a real token, and the public API must not
    /// grow a parameter no host should ever pass.
    func collectAppleSearchAdsAttribution(
        tokenOverride: (@Sendable () throws -> String)?
    ) async {
        let cid = customerId()
        guard config.storage.get(Keys.appleSearchAds(cid)) == nil else { return }

        if config.storage.get(Keys.installedAt) == nil {
            config.storage.set(Keys.installedAt, String(nowMs()))
        }

        if let installedAt = config.storage.get(Keys.installedAt).flatMap(Int.init),
            installedAt > 0, nowMs() - installedAt > Self.serverReattributionWindowMs
        {
            config.storage.set(Keys.appleSearchAds(cid), "1")
            return
        }

        #if canImport(AdServices)
            let token: String
            do {
                token = try (tokenOverride ?? { try AAAttribution.attributionToken() })()
            } catch {
                diagnostic(op: "collectAppleSearchAdsAttribution", message: "\(error)")
                return
            }
            guard !token.isEmpty else { return }
            guard token.count <= 2048 else {
                config.storage.set(Keys.appleSearchAds(cid), "1")
                return
            }
            let body: [String: JSONValue] = [
                "customerId": .string(cid),
                "attributionToken": .string(token),
            ]
            do {
                let data = try await request(
                    path: "/v1/installs", method: "POST", body: body,
                    headers: await deviceHeaders())
                let status = (try? decode(InstallResponse.self, from: data))?.appleAttribution
                if status == "resolved" || status == "organic" {
                    config.storage.set(Keys.appleSearchAds(cid), "1")
                }
                refreshAttribution()
            } catch {
                bgFailures += 1
                diagnostic(op: "collectAppleSearchAdsAttribution", message: "\(error)")
            }
        #else
            config.storage.set(Keys.appleSearchAds(cid), "1")
        #endif
    }

    // MARK: - Install attribution (AT11)

    /// The install-attribution verdict for this customer — which campaign,
    /// link or referrer this install was credited to, and how confidently.
    /// Fetched fresh on every call rather than cached in memory, since the
    /// point is to answer with whatever the server currently believes.
    ///
    /// `nil` means no verdict: none has been recorded yet (a normal race on
    /// the first cold start, before the install report lands), or the read
    /// failed — a failure reports to `onDiagnostic` as `getAttribution`.
    /// Never throws. A verdict that DIFFERS from the last one seen also
    /// reaches `RevnixConfig.onAttribution`, so a host that only wants
    /// updates need not call this at all.
    public func getAttribution() async -> RevnixAttribution? {
        do {
            let data = try await request(
                path: "/v1/customers/\(encode(customerId()))/attribution", method: "GET")
            guard try decode(InstallMatchOnly.self, from: data).installMatch != "unknown"
            else { return nil }
            let attribution = try decode(RevnixAttribution.self, from: data)
            await deliverAttribution(attribution)
            return attribution
        } catch {
            bgFailures += 1
            diagnostic(op: "getAttribution", message: "\(error)")
            return nil
        }
    }

    private struct InstallMatchOnly: Decodable {
        let installMatch: String
    }

    private func deliverAttribution(_ attribution: RevnixAttribution) async {
        let cached = config.storage.get(Keys.attribution)
            .flatMap { try? JSONDecoder().decode(RevnixAttribution.self, from: Data($0.utf8)) }
        guard cached != attribution else { return }
        if let data = try? JSONEncoder().encode(attribution),
            let raw = String(data: data, encoding: .utf8)
        {
            config.storage.set(Keys.attribution, raw)
        } else {
            diagnostic(op: "getAttribution", message: "could not store the attribution verdict")
        }
        guard let handler = config.onAttribution else { return }
        await MainActor.run { handler(attribution) }
    }

    private func refreshAttribution() {
        guard config.onAttribution != nil else { return }
        Task { [weak self] in _ = await self?.getAttribution() }
    }

    func setSkanUpdater(_ updater: SkanUpdater?) {
        skanUpdater = updater
    }

    private func updateSkan(_ value: Int, _ coarse: RevnixCoarseValue?, _ lockWindow: Bool)
        async throws
    {
        skanUpdatesInFlight += 1
        defer { skanUpdatesInFlight -= 1 }
        try await (skanUpdater ?? RevnixSkan.update)(value, coarse, lockWindow)
    }

    private func markSkanRegistered() {
        config.storage.set(Keys.skanRegistered, "1")
    }

    /// Reports a SKAdNetwork conversion value to Apple — never to Revnix. The
    /// fine value is 0…63; a value outside that range is refused here rather
    /// than thrown away inside Apple's API. `coarse`/`lockWindow` need iOS
    /// 16.1; below that only the fine value is sent.
    public func updateSkanConversionValue(
        _ value: Int, coarse: RevnixCoarseValue? = nil, lockWindow: Bool = false
    ) async {
        guard config.skan else {
            diagnostic(op: "updateSkanConversionValue", message: "skan disabled by config")
            return
        }
        guard (0...63).contains(value) else {
            diagnostic(
                op: "updateSkanConversionValue", message: "conversion value \(value) out of 0...63")
            return
        }
        if lockWindow, coarse == nil {
            diagnostic(
                op: "updateSkanConversionValue",
                message:
                    "Apple ignores lockWindow without a coarse value; sending \(value) unlocked")
        }
        do {
            try await updateSkan(value, coarse, lockWindow)
        } catch {
            diagnostic(op: "updateSkanConversionValue", message: "\(error)")
            return
        }
        skanRegisteredByHostUpdate = true
        markSkanRegistered()
    }

    /// Registers the app for SKAdNetwork attribution, once per install. Apple
    /// generates no install postback at all until this call happens.
    private func armSkan() async {
        guard config.skan, skanUpdater != nil || RevnixSkan.isSupported else { return }
        guard skanUpdatesInFlight == 0, config.storage.get(Keys.skanRegistered) == nil else {
            return
        }
        // Latched before the await, not after: a second `registerInstall` must
        // see the claim. A genuine failure gives it back for the next launch.
        markSkanRegistered()
        do {
            try await updateSkan(0, nil, false)
        } catch {
            if !skanRegisteredByHostUpdate {
                config.storage.remove(Keys.skanRegistered)
            }
            diagnostic(op: "armSkan", message: "\(error)")
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
        // REV-272 LOOP GUARD: a display whose placement is one of the six came
        // FROM an implicit trigger, so its dismissal must not fire another one
        // — otherwise "show a win-back when a paywall is declined" hands the
        // customer the same screen until they force-quit. Recognised from the
        // placementKey the caller reports; a caller that reports none cannot
        // be protected here, which is why the server keeps its own
        // same-paywall backstop.
        if implicitEnabled, let key = placementKey,
            RevnixImplicitPlacement(rawValue: key) != nil
        {
            implicitViewIds.insert(viewId)
        }
        guard placementKey != revnixPreviewPlacementKey else { return viewId }
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
    ///
    /// A close is a DECLINE. Do not report one for a display that ended in a
    /// purchase — with implicit placements on, a close is also the
    /// `paywall_decline` moment, and a win-back offer seconds after a
    /// successful purchase is the one thing an operator never means.
    /// `RevnixPaywallView` only reports its close affordances, never a
    /// purchase-driven dismissal.
    public func logPaywallClosed(viewId: String, placementKey: String?, paywallId: String?) async {
        guard placementKey != revnixPreviewPlacementKey else { return }
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
        // REV-272: the dismissal IS the `paywall_decline` moment. No second
        // ledger event — the server reuses the paywall.closed just reported —
        // so this is only the resolve that decides what is attached to it.
        await fireImplicitFromPaywall(
            .paywallDecline, viewId: viewId, paywallId: paywallId)
    }

    /// Report one of the six paywall interactions (REV-263) — what the
    /// customer DID on a display, between the `logPaywallDisplay` that opened
    /// it and the `logPaywallClosed` (or purchase) that ended it.
    ///
    /// Fire-and-forget like the other beacons: never throws.
    ///
    /// `viewId` is the id `logPaywallDisplay` returned for THIS display.
    /// Passing it is what threads the whole life of one impression together
    /// and puts the event on the paywall's own analytics row.
    ///
    /// `RevnixPaywallView` reports `.selected`, `.purchaseStarted`,
    /// `.restore` and a no-products `.error` for you. The purchase OUTCOME is
    /// yours: only your app performs the StoreKit call, so report
    /// `.purchaseAbandoned` / `.purchaseFailed` from your own error handling
    /// (`Product.PurchaseResult.userCancelled` is an abandonment, a thrown
    /// `StoreKitError` is a failure).
    ///
    /// `eventId` is the idempotency key and defaults to `viewId`, which caps
    /// the report at one per display per event. Pass one per occurrence — and
    /// reuse it across your own retries — to record each occurrence.
    public func logPaywallEvent(
        _ event: RevnixPaywallEvent,
        viewId: String,
        placementKey: String? = nil,
        paywallId: String? = nil,
        productId: String? = nil,
        code: String? = nil,
        message: String? = nil,
        eventId: String? = nil
    ) async {
        guard placementKey != revnixPreviewPlacementKey else { return }
        var body: [String: JSONValue] = [
            "customerId": .string(customerId()),
            "viewId": .string(viewId),
            "event": .string(event.rawValue),
            "sdkVersion": .string(Self.sdkVersion),
        ]
        if let v = eventId { body["eventId"] = .string(v) }
        if let v = placementKey { body["placementKey"] = .string(v) }
        if let v = paywallId { body["paywallId"] = .string(v) }
        if let v = productId { body["productId"] = .string(v) }
        if let v = code { body["code"] = .string(v) }
        // The server bounds `message` at 1024; trimming here keeps a long
        // localized store error from turning the whole report into a 400.
        if let v = message { body["message"] = .string(String(v.prefix(1024))) }
        do {
            _ = try await request(path: "/v1/paywalls/events", method: "POST", body: body)
        } catch {
            bgFailures += 1
            diagnostic(op: "logPaywallEvent", message: "\(error)")
        }
        // REV-272: backing out of the store sheet is the `transaction_abandon`
        // moment. Reuses the paywall.purchase_abandoned just reported.
        if event == .purchaseAbandoned {
            await fireImplicitFromPaywall(
                .transactionAbandon, viewId: viewId, paywallId: paywallId)
        }
    }

    /// Report impression-level ad revenue from your mediation SDK's paid-event
    /// callback (AdMob `paidEventHandler`, AppLovin MAX `didPayRevenue`).
    /// Fire-and-forget like the other beacons: never throws.
    public func logAdRevenue(
        revenue: Double,
        currency: String,
        network: String? = nil,
        mediation: String? = nil,
        adUnit: String? = nil,
        placement: String? = nil,
        format: String? = nil,
        eventId: String? = nil
    ) async {
        guard revenue.isFinite, revenue > 0 else {
            diagnostic(op: "logAdRevenue", message: "revenue must be a finite value > 0")
            return
        }
        var body: [String: JSONValue] = [
            "customerId": .string(customerId()),
            "revenue": .number(revenue),
            "currency": .string(String(currency.prefix(100))),
            "sdkVersion": .string(Self.sdkVersion),
        ]
        if let v = network { body["network"] = .string(String(v.prefix(100))) }
        if let v = mediation { body["mediation"] = .string(String(v.prefix(100))) }
        if let v = adUnit { body["adUnit"] = .string(String(v.prefix(100))) }
        if let v = placement { body["placement"] = .string(String(v.prefix(100))) }
        if let v = format { body["format"] = .string(String(v.prefix(100))) }
        if let v = eventId { body["eventId"] = .string(String(v.prefix(100))) }
        do {
            _ = try await request(path: "/v1/ad-revenue", method: "POST", body: body)
        } catch {
            bgFailures += 1
            diagnostic(op: "logAdRevenue", message: "\(error)")
        }
    }

    /// PT11: forward an MMP's attribution callback (Adjust, AppsFlyer, …) so
    /// Revnix credits revenue to the right network/campaign.
    /// Fire-and-forget like the other beacons: never throws.
    public func setAttribution(
        provider: String,
        network: String,
        campaign: String? = nil,
        adGroup: String? = nil,
        creative: String? = nil
    ) async {
        let payload = [provider, network, campaign ?? "", adGroup ?? "", creative ?? ""]
            .joined(separator: "\u{1}")
        guard config.storage.get(Keys.lastAttribution) != payload else { return }
        var body: [String: JSONValue] = [
            "customerId": .string(customerId()),
            "provider": .string(String(provider.prefix(100))),
            "network": .string(String(network.prefix(100))),
            "sdkVersion": .string(Self.sdkVersion),
        ]
        if let v = campaign { body["campaign"] = .string(String(v.prefix(100))) }
        if let v = adGroup { body["adGroup"] = .string(String(v.prefix(100))) }
        if let v = creative { body["creative"] = .string(String(v.prefix(100))) }
        do {
            _ = try await request(path: "/v1/attribution", method: "POST", body: body)
            config.storage.set(Keys.lastAttribution, payload)
        } catch {
            bgFailures += 1
            diagnostic(op: "setAttribution", message: "\(error)")
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

    public static let sdkVersion = "0.3.0"

    private func request(
        path: String, method: String, query: [URLQueryItem]? = nil,
        body: [String: JSONValue]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        var url = config.baseURL.appendingPathComponent(path)
        if let query,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(
                CharacterSet(charactersIn: "+&=?/:#"))
            components.percentEncodedQueryItems = query.map {
                URLQueryItem(
                    name: $0.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.name,
                    value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
            }
            url = components.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = config.timeout
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("revnix-swift/\(Self.sdkVersion)", forHTTPHeaderField: "X-Revnix-SDK")
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
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
        static let installedAt = "revnix.installedAt"
        static func cache(_ cid: String) -> String { "revnix.ent.\(cid)" }
        static func placement(_ key: String) -> String { "revnix.placement.\(key)" }
        static func installReported(_ cid: String) -> String {
            "revnix.installReported.\(cid)"
        }
        static func appleSearchAds(_ cid: String) -> String {
            "revnix.appleSearchAds.\(cid)"
        }
        /// Deliberately not per customer id: SKAdNetwork registration is per
        /// install, and `logout()` must not re-arm it.
        static let skanRegistered = "revnix.skanRegistered"
        static let deferredDeepLinkDelivered = "revnix.deferredDeepLinkDelivered"
        static let lastDeepLink = "revnix.lastDeepLink"
        static let attribution = "revnix.attribution"
        static let lastAttribution = "revnix.lastAttribution"
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
