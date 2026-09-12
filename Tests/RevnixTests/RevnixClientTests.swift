import Foundation
import XCTest

@testable import Revnix

/// Behavior tests ported from revnix-react's `resilience.test.ts` — that
/// file is the policy spec; these must stay in agreement with it. Each test
/// notes the spec case it mirrors so drift is visible in review.
final class RevnixClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    // MARK: - Fixtures

    static let dayMs = 24 * 60 * 60 * 1000

    static let entitlementsBody = """
        {"customerId":"cust_1","cursor":7,"entitlements":[{"entitlementId":"pro","isActive":true,"expiresAt":4102444800000,"sources":[{"kind":"subscription","key":"s1","isActive":true,"expiresAt":4102444800000}]}]}
        """

    static let purchaseBody = """
        {"eventId":"evt_1","seq":9,"duplicate":false,"customerId":"cust_1","transferred":false}
        """

    static let placementBody = """
        {"status":"ok","placementKey":"main","revision":1,"offering":{"offeringId":"off_1","displayName":"Default","packages":[{"packageId":"pkg_1","productId":"pro.monthly"}]}}
        """

    /// Entitlements body with an explicit `expiresAt` (REV-157 grace cases).
    static func entitlementsBody(expiresAt: Int?) -> String {
        let expiry = expiresAt.map { "\($0)" } ?? "null"
        return """
            {"customerId":"cust_1","cursor":5,"entitlements":[{"entitlementId":"pro","isActive":true,"expiresAt":\(expiry),"sources":[]}]}
            """
    }

    func makeClient(
        now: @escaping @Sendable () -> Date = { Date() },
        storage: RevnixStorage = MemoryStorage(),
        timeout: TimeInterval = 10,
        entitlementsTTL: TimeInterval = 30,
        readYourWritesDelays: [TimeInterval] = [0.25, 0.5, 1, 2],
        onDiagnostic: (@Sendable (RevnixDiagnostic) -> Void)? = nil,
        device: DeviceFacts? = RevnixClientTests.fixedDevice
    ) -> RevnixClient {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        return RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: storage,
                timeout: timeout,
                entitlementsTTL: entitlementsTTL,
                readYourWritesDelays: readYourWritesDelays,
                onDiagnostic: onDiagnostic,
                now: now,
                session: URLSession(configuration: sessionConfig),
                device: device
            ))
    }

    /// REV-268: a fixed device so the header is deterministic. The storefront
    /// is set explicitly so the client never asks StoreKit under test.
    static let fixedDevice = DeviceFacts(
        platform: "ios", osVersion: "18.1", appVersion: "1.2.10", locale: "en_US",
        currency: "USD", storefront: "USA", model: "iPhone15,3", sandbox: true)

    /// Decode the base64url JSON the client put in X-Revnix-Device.
    static func decodeDeviceHeader(_ header: String) throws -> [String: JSONValue] {
        var base64 = header.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    // MARK: - Request timeout (spec: "C7 request timeout")

    func testHungRequestTimesOutRatherThanHanging() async throws {
        StubProtocol.hang(containing: "/placements")
        let client = makeClient(timeout: 0.5)
        do {
            _ = try await client.resolvePlacement("main")
            XCTFail("expected RevnixError.timeout")
        } catch let err as RevnixError {
            XCTAssertEqual(err, .timeout)
            XCTAssertTrue(err.isRetryable)
        }
    }

    // MARK: - Typed errors (spec: "C7 typed errors")

    func testRateLimitCarriesRetryAfterMs() async throws {
        StubProtocol.respond(
            containing: "/placements", status: 429,
            body: #"{"error":"rate limit exceeded"}"#,
            headers: ["Retry-After": "2"])
        let client = makeClient()
        do {
            _ = try await client.resolvePlacement("main")
            XCTFail("expected RevnixError.rateLimited")
        } catch let err as RevnixError {
            XCTAssertEqual(err, .rateLimited(retryAfterMs: 2000))
            XCTAssertEqual(err.retryAfterMs, 2000)
            XCTAssertTrue(err.isRetryable)
        }
    }

    func testRetryAfterAcceptsHTTPDateAndToleratesGarbage() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let httpDate = "Thu, 01 Jan 1970 00:16:50 GMT"  // == 1_010 s
        XCTAssertEqual(
            RevnixError.parseRetryAfter("2"), 2000)
        XCTAssertEqual(
            RevnixError.parseRetryAfter(
                httpDate, now: Date(timeIntervalSince1970: 1_000)), 10_000)
        XCTAssertNil(RevnixError.parseRetryAfter(nil, now: now))
        XCTAssertNil(RevnixError.parseRetryAfter("not-a-date", now: now))
    }

    func testNetworkFailureIsTypedAsNetworkError() async throws {
        StubProtocol.failWithConnectionError(containing: "/placements")
        let client = makeClient()
        do {
            _ = try await client.resolvePlacement("main")
            XCTFail("expected RevnixError.network")
        } catch let err as RevnixError {
            guard case .network = err else {
                return XCTFail("expected .network, got \(err)")
            }
            XCTAssertTrue(err.isRetryable)
        }
    }

    // MARK: - Entitlement cache (spec: "C7 entitlement cache")

    func testEntitlementsHappyPath() async throws {
        StubProtocol.respond(containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        let client = makeClient()
        let result = try await client.entitlements()
        XCTAssertEqual(result.cursor, 7)
        XCTAssertEqual(result.stale, false)
        XCTAssertEqual(result.entitlements.first?.entitlementId, "pro")
        let entitled = await client.isEntitled("pro")
        XCTAssertTrue(entitled)
        let notEntitled = await client.isEntitled("gold")
        XCTAssertFalse(notEntitled)
    }

    func testFallsBackToCacheWhenNetworkReadFails() async throws {
        StubProtocol.respondOnce(
            containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        StubProtocol.failWithConnectionError(containing: "/entitlements")
        // TTL off so the second read genuinely exercises the offline path.
        let client = makeClient(entitlementsTTL: 0)

        let fresh = try await client.entitlements()
        XCTAssertEqual(fresh.stale, false)
        XCTAssertEqual(fresh.entitlements.first?.entitlementId, "pro")

        // Network is down now → the paying customer is still shown entitled.
        let cached = try await client.entitlements()
        XCTAssertEqual(cached.stale, true)
        XCTAssertEqual(cached.entitlements.first?.isActive, true)
        let entitled = await client.isEntitled("pro")
        XCTAssertTrue(entitled)
    }

    func testTransientFailureServesCacheStale() async throws {
        StubProtocol.respond(containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        // Inject time so the second call is outside the 30 s soft TTL.
        let clock = Clock(start: Date())
        let client = makeClient(now: { clock.now() })
        _ = try await client.entitlements()

        clock.advance(by: 60)
        StubProtocol.respond(containing: "/entitlements", status: 500, body: #"{"error":"boom"}"#)
        let served = try await client.entitlements()
        XCTAssertEqual(served.stale, true)
        XCTAssertEqual(served.entitlements.first?.isActive, true)
    }

    func testCachedEntitlementsReadsCacheWithNoNetworkCall() async throws {
        StubProtocol.respond(containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        let client = makeClient()

        let beforeAnyRead = await client.cachedEntitlements()
        XCTAssertNil(beforeAnyRead)  // nothing cached yet

        _ = try await client.entitlements()  // caches
        let cached = await client.cachedEntitlements()
        XCTAssertEqual(cached?.stale, true)
        XCTAssertEqual(cached?.entitlements.first?.entitlementId, "pro")
        // Only the one live fetch happened.
        XCTAssertEqual(StubProtocol.requestCount(containing: "/entitlements"), 1)
    }

    // MARK: - Local expiry grace (spec: "REV-157 local expiry")

    /// Warm the cache from a live read, then go offline and serve from cache.
    private func cachedServe(
        expiresAt: Int?, storage: RevnixStorage = MemoryStorage()
    ) async throws -> (client: RevnixClient, cached: CustomerEntitlements) {
        StubProtocol.respondOnce(
            containing: "/entitlements", status: 200,
            body: Self.entitlementsBody(expiresAt: expiresAt))
        StubProtocol.failWithConnectionError(containing: "/entitlements")
        let client = makeClient(storage: storage, entitlementsTTL: 0)
        let fresh = try await client.entitlements()
        // The fresh read is authoritative — served verbatim even when the
        // local clock disagrees.
        XCTAssertEqual(fresh.entitlements.first?.isActive, true)
        return (client, try await client.entitlements())
    }

    func testExpiredBeyondGraceServedInactiveFromCache() async throws {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let (client, cached) = try await cachedServe(expiresAt: nowMs - 5 * Self.dayMs)
        XCTAssertEqual(cached.stale, true)
        XCTAssertEqual(cached.entitlements.first?.isActive, false)
        let entitled = await client.isEntitled("pro")
        XCTAssertFalse(entitled)
    }

    func testExpiredWithinGraceStillActive() async throws {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        // The renewal an offline device cannot see.
        let (client, cached) = try await cachedServe(expiresAt: nowMs - 1 * Self.dayMs)
        XCTAssertEqual(cached.stale, true)
        XCTAssertEqual(cached.entitlements.first?.isActive, true)
        let entitled = await client.isEntitled("pro")
        XCTAssertTrue(entitled)
    }

    func testNoExpiresAtIsUntouched() async throws {
        let (_, cached) = try await cachedServe(expiresAt: nil)
        XCTAssertEqual(cached.entitlements.first?.isActive, true)
    }

    func testCachedEntitlementsAppliesTheSameExpiryEvaluation() async throws {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let (client, _) = try await cachedServe(expiresAt: nowMs - 5 * Self.dayMs)
        let cached = await client.cachedEntitlements()
        XCTAssertEqual(cached?.entitlements.first?.isActive, false)
    }

    // MARK: - Persisted purchase retry (spec: "C7 persisted purchase retry")

    func testPurchaseRetryQueuePersistsAndDrains() async throws {
        StubProtocol.failWithConnectionError(containing: "/purchases")
        let storage = MemoryStorage()
        let client = makeClient(storage: storage)
        let input = RegisterPurchaseInput(
            source: .apple, token: "orig.1", productId: "pro.monthly",
            transactionId: "txn.1")
        do {
            _ = try await client.registerPurchase(input)
            XCTFail("expected a retryable failure")
        } catch let err as RevnixError {
            XCTAssertTrue(err.isRetryable)
        }
        let queuedCount = await client.pendingPurchaseCount()
        XCTAssertEqual(queuedCount, 1)
        // Persisted under the documented key, keyed source:token:transactionId.
        let raw = storage.get("revnix.pendingPurchases")
        XCTAssertNotNil(raw)
        XCTAssertTrue(raw?.contains("apple:orig.1:txn.1") ?? false)

        // A later launch with connectivity drains the queue (idempotent
        // server-side via the shared purchaseKey). A FRESH client proves the
        // queue survived process death, not just in-memory state.
        StubProtocol.respond(containing: "/purchases", status: 201, body: Self.purchaseBody)
        let relaunched = makeClient(storage: storage)
        let delivered = await relaunched.retryPendingPurchases()
        XCTAssertEqual(delivered, 1)
        let remaining = await relaunched.pendingPurchaseCount()
        XCTAssertEqual(remaining, 0)
    }

    func testSameFailingPurchaseIsNotQueuedTwice() async throws {
        StubProtocol.failWithConnectionError(containing: "/purchases")
        let client = makeClient()
        let input = RegisterPurchaseInput(
            source: .apple, token: "orig.1", productId: "pro.monthly",
            transactionId: "txn.1")
        _ = try? await client.registerPurchase(input)
        _ = try? await client.registerPurchase(input)
        let queuedCount = await client.pendingPurchaseCount()
        XCTAssertEqual(queuedCount, 1)
    }

    func testDeliberatePurchaseRejectionIsNotQueued() async throws {
        StubProtocol.respond(
            containing: "/purchases", status: 409, body: #"{"error":"blocked"}"#)
        let client = makeClient()
        let input = RegisterPurchaseInput(
            source: .apple, token: "orig.2", productId: "pro.monthly",
            transactionId: "txn.2")
        do {
            _ = try await client.registerPurchase(input)
            XCTFail("expected purchaseBlocked")
        } catch let err as RevnixError {
            XCTAssertFalse(err.isRetryable)
        }
        let queuedCount = await client.pendingPurchaseCount()
        XCTAssertEqual(queuedCount, 0)
    }

    // MARK: - Cache fallback discipline (spec: "REV-198 cache fallback discipline")

    func testRevokedKey401IsNotPaperedOverByTheCache() async throws {
        StubProtocol.respondOnce(
            containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        StubProtocol.respond(
            containing: "/entitlements", status: 401, body: #"{"error":"revoked"}"#)
        let client = makeClient(entitlementsTTL: 0)
        _ = try await client.entitlements()  // cached
        do {
            _ = try await client.entitlements()
            XCTFail("expected RevnixError.auth")
        } catch let err as RevnixError {
            XCTAssertEqual(err, .auth(401))
            XCTAssertFalse(err.isRetryable)
        }
    }

    func testIsEntitledAnswersFalseForARevokedKeyEvenWithAnActiveEntitlementCached() async throws {
        StubProtocol.respondOnce(
            containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        StubProtocol.respond(
            containing: "/entitlements", status: 401, body: #"{"error":"revoked"}"#)
        let client = makeClient(entitlementsTTL: 0)
        _ = try await client.entitlements()
        let entitled = await client.isEntitled("pro")
        XCTAssertFalse(entitled)
    }

    func testIsEntitledStillServesTheCacheOnATransientFailure() async throws {
        StubProtocol.respondOnce(
            containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        StubProtocol.respond(
            containing: "/entitlements", status: 500, body: #"{"error":"boom"}"#)
        let client = makeClient(entitlementsTTL: 0)
        _ = try await client.entitlements()
        let entitled = await client.isEntitled("pro")
        XCTAssertTrue(entitled)
    }

    func testUnknownPlacement404IsNotPaperedOverByTheCache() async throws {
        StubProtocol.respondOnce(
            containing: "/placements", status: 200, body: Self.placementBody)
        StubProtocol.respond(
            containing: "/placements", status: 404,
            body: #"{"error":"unknown placement"}"#)
        let client = makeClient()
        _ = try await client.resolvePlacement("main")  // cached
        do {
            _ = try await client.resolvePlacement("main")
            XCTFail("expected RevnixError.notFound")
        } catch let err as RevnixError {
            XCTAssertEqual(err, .notFound)
            XCTAssertFalse(err.isRetryable)
        }
    }

    func test500StillFallsBackToTheCache() async throws {
        StubProtocol.respondOnce(
            containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        StubProtocol.respond(
            containing: "/entitlements", status: 500, body: #"{"error":"boom"}"#)
        let client = makeClient(entitlementsTTL: 0)
        _ = try await client.entitlements()
        let cached = try await client.entitlements()
        XCTAssertEqual(cached.stale, true)
        XCTAssertEqual(cached.entitlements.first?.isActive, true)
    }

    // MARK: - Offline cache age bound (spec: "REV-198 offline cache age bound")

    func testCacheAgeCeilingServesInactive() async throws {
        StubProtocol.respond(containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        let clock = Clock(start: Date())
        let client = makeClient(now: { clock.now() })
        _ = try await client.entitlements()

        // 15 days later, offline: past the 14-day ceiling → all inactive.
        clock.advance(by: 15 * 24 * 3600)
        StubProtocol.respond(containing: "/entitlements", status: 500, body: #"{"error":"down"}"#)
        let served = try await client.entitlements()
        XCTAssertEqual(served.stale, true)
        XCTAssertEqual(served.entitlements.first?.isActive, false)
    }

    func testWithinTheOfflineWindowItStillGrants() async throws {
        StubProtocol.respond(containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        let clock = Clock(start: Date())
        let client = makeClient(now: { clock.now() })
        _ = try await client.entitlements()

        // 13 days later, offline: inside the 14-day ceiling → still granted.
        clock.advance(by: 13 * 24 * 3600)
        StubProtocol.respond(containing: "/entitlements", status: 500, body: #"{"error":"down"}"#)
        let served = try await client.entitlements()
        XCTAssertEqual(served.stale, true)
        XCTAssertEqual(served.entitlements.first?.isActive, true)
    }

    func testClockRollbackServesInactive() async throws {
        StubProtocol.respond(containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        let clock = Clock(start: Date())
        let client = makeClient(now: { clock.now() })
        _ = try await client.entitlements()

        // Roll the clock back 30 minutes, go offline → all inactive.
        clock.advance(by: -1800)
        StubProtocol.respond(containing: "/entitlements", status: 500, body: #"{"error":"down"}"#)
        let served = try await client.entitlements()
        XCTAssertEqual(served.stale, true)
        XCTAssertEqual(served.entitlements.first?.isActive, false)
    }

    // MARK: - Soft TTL + coalescing (spec: "REV-199 entitlement read TTL")

    func testReadsWithinTTLCostOneRequestAndConcurrentReadsShareOne() async throws {
        StubProtocol.respond(containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        let client = makeClient()

        // Concurrent burst — a screen full of gates → one request.
        async let a = client.isEntitled("pro")
        async let b = client.isEntitled("pro")
        async let c = client.entitlements()
        _ = await a
        _ = await b
        _ = try await c
        XCTAssertEqual(StubProtocol.requestCount(containing: "/entitlements"), 1)

        // Within the TTL → still one.
        _ = try await client.entitlements()
        XCTAssertEqual(StubProtocol.requestCount(containing: "/entitlements"), 1)
    }

    func testTTLZeroRestoresAlwaysFetch() async throws {
        StubProtocol.respond(containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        let client = makeClient(entitlementsTTL: 0)
        _ = try await client.entitlements()
        _ = try await client.entitlements()
        XCTAssertEqual(StubProtocol.requestCount(containing: "/entitlements"), 2)
    }

    /// Regression: `waitForEntitlements` must bypass the soft TTL. Polling
    /// through the TTL re-read the SAME cached snapshot, so the cursor never
    /// advanced and every post-purchase unlock spun until it gave up whenever
    /// a gate had been checked in the preceding 30 s.
    func testWaitForEntitlementsBypassesTheSoftTTL() async throws {
        StubProtocol.respondOnce(
            containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        StubProtocol.respond(
            containing: "/entitlements", status: 200,
            body: """
                {"customerId":"cust_1","cursor":9,"entitlements":[{"entitlementId":"pro","isActive":true,"expiresAt":4102444800000,"sources":[]}]}
                """)
        // Default 30 s TTL stays ON — that is the point of the regression.
        let client = makeClient()
        let first = try await client.entitlements()
        XCTAssertEqual(first.cursor, 7)

        let settled = try await client.waitForEntitlements(seq: 9)
        XCTAssertEqual(settled.cursor, 9)
        XCTAssertEqual(settled.stale, false)
    }

    /// The poll resolves with the LAST read rather than throwing when the
    /// ledger never catches up — a slow ledger is "not unlocked yet", not an
    /// error every caller has to handle.
    func testWaitForEntitlementsReturnsLastReadWhenCursorNeverCatchesUp() async throws {
        StubProtocol.respond(containing: "/entitlements", status: 200, body: Self.entitlementsBody)
        let client = makeClient(readYourWritesDelays: [0.01, 0.01])
        let settled = try await client.waitForEntitlements(seq: 999)
        XCTAssertEqual(settled.cursor, 7)  // never reached 999, still returned
    }

    // MARK: - Paywall config decoding (spec: react `PaywallConfig` templates)

    /// A template-gallery config exercising every new field: a post-expansion
    /// layout ("offer"), light mode, review + offer blocks, footer URLs — and
    /// an unknown key, which Codable must ignore.
    func testPaywallFullTemplateConfigDecodes() async throws {
        StubProtocol.respond(
            containing: "/placements", status: 200,
            body: """
                {"status":"ok","placementKey":"main","revision":3,"offering":{"offeringId":"off_1","displayName":"Default","packages":[{"packageId":"pkg_1","productId":"pro.monthly"}]},"paywall":{"paywallId":"pw_1","name":"Winback","config":{"template":"offer","mode":"light","headline":"Come back","subheadline":"We missed you","features":[{"icon":"star","title":"Everything","description":"All features"}],"ctaLabel":"Claim offer","highlightPackageId":"pkg_1","badgeText":"SAVE 17%","accent":"#6478ff","heroImageUrl":"https://cdn.example/hero.png","review":{"rating":4.8,"quote":"Life-changing","author":"Sam","count":"Join 2M+ users"},"offer":{"strikethroughPrice":"$9.99","urgencyText":"Ends tonight"},"footer":{"showRestore":true,"showTerms":true,"showPrivacy":false,"termsUrl":"https://example.com/terms"},"someFutureField":{"nested":true}}}}
                """)
        let client = makeClient()
        let resolution = try await client.resolvePlacement("main")
        let paywall = try XCTUnwrap(resolution.paywall)
        XCTAssertEqual(paywall.paywallId, "pw_1")
        XCTAssertEqual(paywall.name, "Winback")
        XCTAssertEqual(paywall.config.template, "offer")
        XCTAssertEqual(paywall.config.mode, "light")
        XCTAssertEqual(paywall.config.headline, "Come back")
        XCTAssertEqual(paywall.config.features.first?.icon, "star")
        XCTAssertEqual(paywall.config.review?.rating, 4.8)
        XCTAssertEqual(paywall.config.review?.count, "Join 2M+ users")
        XCTAssertEqual(paywall.config.offer?.strikethroughPrice, "$9.99")
        XCTAssertEqual(paywall.config.offer?.urgencyText, "Ends tonight")
        XCTAssertEqual(paywall.config.footer?.showPrivacy, false)
        XCTAssertEqual(paywall.config.footer?.termsUrl, "https://example.com/terms")
        XCTAssertNil(paywall.config.footer?.privacyUrl)
    }

    /// A pre-expansion config (original "focus" template, no mode/review/
    /// offer/footer) must keep decoding — and a resolution with no paywall
    /// at all still decodes with `paywall == nil`.
    func testLegacyMinimalPaywallConfigStillDecodes() async throws {
        StubProtocol.respondOnce(
            containing: "/placements", status: 200,
            body: """
                {"status":"ok","placementKey":"main","revision":1,"offering":{"offeringId":"off_1","displayName":"Default","packages":[{"packageId":"pkg_1","productId":"pro.monthly"}]},"paywall":{"paywallId":"pw_0","name":"Legacy","config":{"template":"focus","headline":"Go Pro","features":[{"title":"Unlimited"}],"ctaLabel":"Subscribe"}}}
                """)
        StubProtocol.respond(containing: "/placements", status: 200, body: Self.placementBody)
        let client = makeClient()
        let legacy = try await client.resolvePlacement("main")
        let paywall = try XCTUnwrap(legacy.paywall)
        XCTAssertEqual(paywall.config.template, "focus")
        XCTAssertNil(paywall.config.mode)
        XCTAssertEqual(paywall.config.features, [
            PaywallFeature(icon: nil, title: "Unlimited", description: nil)
        ])
        XCTAssertNil(paywall.config.review)
        XCTAssertNil(paywall.config.offer)
        XCTAssertNil(paywall.config.footer)

        // Fixture without a `paywall` key at all.
        let bare = try await client.resolvePlacement("main")
        XCTAssertNil(bare.paywall)
    }

    // MARK: - Experiments (spec: "REV-219 A/B experiments")

    static let experimentPlacementBody = """
        {"status":"ok","placementKey":"main","revision":4,"offering":{"offeringId":"off_2","displayName":"Variant B","packages":[{"packageId":"pkg_2","productId":"pro.annual"}]},"experiment":{"key":"summer-pricing","variantId":"var_b"}}
        """

    /// The resolve carries the customer id (URL-encoded) so the server can
    /// pin a sticky variant, and the assignment decodes off the response.
    func testResolveSendsCustomerIdAndDecodesExperiment() async throws {
        StubProtocol.respond(
            containing: "/placements", status: 200, body: Self.experimentPlacementBody)
        let storage = MemoryStorage()
        // An id with a space proves the query item is percent-encoded.
        storage.set("revnix.customerId", "cust one")
        let client = makeClient(storage: storage)
        let resolution = try await client.resolvePlacement("main")
        XCTAssertEqual(
            resolution.experiment,
            PlacementExperiment(key: "summer-pricing", variantId: "var_b"))
        let path = try XCTUnwrap(StubProtocol.lastPath(containing: "/placements"))
        XCTAssertTrue(path.hasSuffix("/offering?customer=cust%20one"), path)
    }

    // MARK: - Device attribute contract (REV-268)

    /// Every resolve carries the device facts, base64url-encoded, with the
    /// three SDK-owned fields added: sdkVersion, installedAt, firstOpen.
    func testResolvePlacementSendsDeviceFactsHeader() async throws {
        StubProtocol.respond(
            containing: "/placements", status: 200, body: Self.placementBody)
        let storage = MemoryStorage()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let client = makeClient(now: { fixedNow }, storage: storage)
        _ = try await client.resolvePlacement("main")
        let header = try XCTUnwrap(
            StubProtocol.lastHeader("X-Revnix-Device", containing: "/placements"))
        let facts = try Self.decodeDeviceHeader(header)
        XCTAssertEqual(facts["platform"], .string("ios"))
        XCTAssertEqual(facts["osVersion"], .string("18.1"))
        XCTAssertEqual(facts["appVersion"], .string("1.2.10"))
        XCTAssertEqual(facts["locale"], .string("en_US"))
        XCTAssertEqual(facts["currency"], .string("USD"))
        XCTAssertEqual(facts["storefront"], .string("USA"))
        XCTAssertEqual(facts["model"], .string("iPhone15,3"))
        XCTAssertEqual(facts["sandbox"], .bool(true))
        XCTAssertEqual(facts["sdkVersion"], .string(RevnixClient.sdkVersion))
        XCTAssertEqual(facts["installedAt"], .number(1_700_000_000_000))
        XCTAssertEqual(facts["firstOpen"], .bool(true))
        XCTAssertEqual(storage.get("revnix.installedAt"), "1700000000000")

        // A later session on the same storage: same install date, no longer
        // the first open.
        let later = makeClient(
            now: { fixedNow.addingTimeInterval(86_400) }, storage: storage)
        _ = try await later.resolvePlacement("main")
        let second = try Self.decodeDeviceHeader(
            try XCTUnwrap(
                StubProtocol.lastHeader("X-Revnix-Device", containing: "/placements")))
        XCTAssertEqual(second["installedAt"], .number(1_700_000_000_000))
        XCTAssertEqual(second["firstOpen"], .bool(false))
    }

    /// `device: nil` sends nothing — the header is absent, not empty.
    func testDeviceFactsCanBeDisabled() async throws {
        StubProtocol.respond(
            containing: "/placements", status: 200, body: Self.placementBody)
        let client = makeClient(device: nil)
        _ = try await client.resolvePlacement("main")
        XCTAssertNil(StubProtocol.lastHeader("X-Revnix-Device", containing: "/placements"))
    }

    /// `detect()` answers from the running process: a platform name, an OS
    /// version and a locale exist on every Apple platform the tests run on.
    func testDetectFillsProcessFacts() {
        let facts = DeviceFacts.detect()
        XCTAssertEqual(facts.platform, DeviceFacts.platformName)
        XCTAssertNotNil(facts.osVersion)
        XCTAssertNotNil(facts.locale)
        XCTAssertNil(facts.storefront, "storefront is StoreKit's, asked lazily")
    }

    /// `experiment` is null when nothing is running, and absent entirely on
    /// older servers — both must decode to nil.
    func testExperimentNullAndAbsentBothDecodeToNil() async throws {
        StubProtocol.respondOnce(
            containing: "/placements", status: 200,
            body: """
                {"status":"ok","placementKey":"main","revision":1,"offering":{"offeringId":"off_1","displayName":"Default","packages":[]},"experiment":null}
                """)
        StubProtocol.respond(containing: "/placements", status: 200, body: Self.placementBody)
        let client = makeClient()
        let nullCase = try await client.resolvePlacement("main")
        XCTAssertNil(nullCase.experiment)
        let absentCase = try await client.resolvePlacement("main")
        XCTAssertNil(absentCase.experiment)
    }

    /// The assignment must survive the offline fallback — attribution from a
    /// cached resolution has to name the same variant that was served.
    func testExperimentRoundTripsThroughThePlacementCache() async throws {
        StubProtocol.respondOnce(
            containing: "/placements", status: 200, body: Self.experimentPlacementBody)
        StubProtocol.failWithConnectionError(containing: "/placements")
        let client = makeClient()
        _ = try await client.resolvePlacement("main")  // cached
        let cached = try await client.resolvePlacement("main")
        XCTAssertEqual(
            cached.experiment,
            PlacementExperiment(key: "summer-pricing", variantId: "var_b"))
    }

    // MARK: - Raw wire passthrough (bridges that render the paywall themselves)

    static let designedPlacementBody = """
        {"status":"ok","placementKey":"main","revision":5,"offering":{"offeringId":"off_3","displayName":"Designed","packages":[{"packageId":"pkg_3","productId":"pro.yearly"}]},"paywall":{"paywallId":"pw_1","name":"Main","config":{"template":"focus","headline":"Unlock","ctaLabel":"Go","blocks":{"version":1,"layout":"flow","blocks":[{"type":"hologram","spin":3}]},"futureField":"kept"}},"experiment":{"key":"summer-pricing","variantId":"var_b"}}
        """

    /// `paywallJSON` / `experimentJSON` are the wire values untouched: a block
    /// type and a config field this SDK does not know survive there, while the
    /// typed `paywall` still decodes beside them.
    func testRawPaywallAndExperimentSurviveBesideTheTypedViews() async throws {
        StubProtocol.respond(
            containing: "/placements", status: 200, body: Self.designedPlacementBody)
        let client = makeClient()
        let resolution = try await client.resolvePlacement("main")

        XCTAssertEqual(resolution.paywall?.paywallId, "pw_1")
        guard case .object(let paywall)? = resolution.paywallJSON,
            case .object(let config)? = paywall["config"],
            case .object(let blocks)? = config["blocks"],
            case .array(let items)? = blocks["blocks"],
            case .object(let item)? = items.first
        else { return XCTFail("paywallJSON should mirror the wire document") }
        XCTAssertEqual(config["futureField"], .string("kept"))
        XCTAssertEqual(item["type"], .string("hologram"))
        XCTAssertEqual(
            resolution.experimentJSON,
            .object(["key": .string("summer-pricing"), "variantId": .string("var_b")]))
    }

    /// The raw copy is what the offline cache stores, so a cached resolution
    /// hands a bridge the same document the live one did.
    func testRawPaywallRoundTripsThroughThePlacementCache() async throws {
        StubProtocol.respondOnce(
            containing: "/placements", status: 200, body: Self.designedPlacementBody)
        StubProtocol.failWithConnectionError(containing: "/placements")
        let client = makeClient()
        let live = try await client.resolvePlacement("main")
        let cached = try await client.resolvePlacement("main")
        XCTAssertEqual(cached.paywallJSON, live.paywallJSON)
        XCTAssertEqual(cached.experimentJSON, live.experimentJSON)
        XCTAssertEqual(cached.paywall, live.paywall)
    }

    /// A paywall the typed model cannot read (here: no `headline` /
    /// `ctaLabel`, and an experiment missing `variantId`) must not fail the
    /// resolution — the offering and the raw copies still arrive, the typed
    /// views are simply nil. Same rule `PaywallConfig` applies to `blocks`.
    func testUntypeablePaywallStillDeliversTheOfferingAndRawCopies() async throws {
        StubProtocol.respond(
            containing: "/placements", status: 200,
            body: """
                {"status":"ok","placementKey":"main","revision":6,"offering":{"offeringId":"off_4","displayName":"Blocks only","packages":[{"packageId":"pkg_4","productId":"pro.weekly"}]},"paywall":{"paywallId":"pw_2","name":"Next","config":{"template":"canvas","blocks":{"version":2,"layout":"grid","blocks":[]}}},"experiment":{"key":"k"}}
                """)
        let client = makeClient()
        let resolution = try await client.resolvePlacement("main")
        XCTAssertEqual(resolution.offering.offeringId, "off_4")
        XCTAssertNil(resolution.paywall)
        XCTAssertNil(resolution.experiment)
        guard case .object(let paywall)? = resolution.paywallJSON else {
            return XCTFail("raw paywall should survive an untypeable config")
        }
        XCTAssertEqual(paywall["paywallId"], .string("pw_2"))
        XCTAssertEqual(resolution.experimentJSON, .object(["key": .string("k")]))
    }

    /// No paywall and no experiment on the wire → both raw copies are nil,
    /// whether the keys are null or missing.
    func testRawCopiesAreNilWhenTheWireHasNone() async throws {
        StubProtocol.respondOnce(
            containing: "/placements", status: 200,
            body: """
                {"status":"ok","placementKey":"main","revision":1,"offering":{"offeringId":"off_1","displayName":"Default","packages":[]},"paywall":null,"experiment":null}
                """)
        StubProtocol.respond(containing: "/placements", status: 200, body: Self.placementBody)
        let client = makeClient()
        let nullCase = try await client.resolvePlacement("main")
        XCTAssertNil(nullCase.paywallJSON)
        XCTAssertNil(nullCase.experimentJSON)
        let absentCase = try await client.resolvePlacement("main")
        XCTAssertNil(absentCase.paywallJSON)
        XCTAssertNil(absentCase.experimentJSON)
    }

    // MARK: - Diagnostics (spec: "REV-200 diagnostics")

    func testBackgroundFailureReachesDiagnosticsAndRidesTheNextRequestHeader() async throws {
        let storage = MemoryStorage()
        // A queued purchase from a "previous launch" whose retry will fail.
        storage.set(
            "revnix.pendingPurchases",
            """
            [{"key":"apple:otx-9:tx-9","source":"apple","token":"otx-9","productId":"pro.monthly","transactionId":"tx-9"}]
            """)
        StubProtocol.failWithConnectionError(containing: "/purchases")
        StubProtocol.respond(containing: "/entitlements", status: 200, body: Self.entitlementsBody)

        let events = Recorder()
        let client = makeClient(
            storage: storage, entitlementsTTL: 0,
            onDiagnostic: { events.record($0.op) })

        let delivered = await client.retryPendingPurchases()
        XCTAssertEqual(delivered, 0)
        XCTAssertGreaterThan(events.count, 0)
        // Retryable failure → the item stays queued for the next launch.
        let stillQueued = await client.pendingPurchaseCount()
        XCTAssertEqual(stillQueued, 1)

        // The counter rides the next successful request…
        _ = try await client.entitlements()
        let header = StubProtocol.lastHeader(
            "X-Revnix-Bg-Failures", containing: "/entitlements")
        XCTAssertNotNil(header)
        XCTAssertGreaterThan(Int(header ?? "0") ?? 0, 0)

        // …and is cleared once delivered.
        _ = try await client.entitlements()
        let cleared = StubProtocol.lastHeader(
            "X-Revnix-Bg-Failures", containing: "/entitlements")
        XCTAssertNil(cleared)
    }

    /// The JS spec asserts a throwing `onDiagnostic` cannot take the SDK down.
    /// A Swift diagnostic closure is non-throwing, so that failure mode is
    /// structurally impossible here; what remains testable is that installing
    /// a handler never swallows or alters the error the caller sees.
    func testDiagnosticHandlerNeverMasksTheUnderlyingError() async throws {
        StubProtocol.failWithConnectionError(containing: "/entitlements")
        let events = Recorder()
        let client = makeClient(onDiagnostic: { events.record($0.op) })
        do {
            _ = try await client.entitlements()
            XCTFail("expected RevnixError.network")
        } catch let err as RevnixError {
            guard case .network = err else {
                return XCTFail("expected .network, got \(err)")
            }
        }
    }
}

// MARK: - Test plumbing

/// Mutable test clock, thread-safe.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(start: Date) { self.current = start }
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// Thread-safe collector for diagnostic callbacks.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ops: [String] = []
    func record(_ op: String) {
        lock.lock()
        defer { lock.unlock() }
        ops.append(op)
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return ops.count
    }
}

/// URLProtocol stub: path-substring → canned response, connection error, or a
/// deliberate hang. Records every request so tests can assert call counts and
/// outbound headers.
final class StubProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let body: String
        let headers: [String: String]
        let connectionError: Bool
        let hang: Bool
    }
    struct Recorded {
        let path: String
        let headers: [String: String]
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [(substring: String, stub: Stub)] = []
    /// One-shot stubs, matched before the persistent ones (mirrors the JS
    /// spec's `mockResolvedValueOnce` sequencing).
    nonisolated(unsafe) private static var onceStubs: [(substring: String, stub: Stub)] = []
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubs = []
        onceStubs = []
        recorded = []
    }

    static func respond(
        containing substring: String, status: Int, body: String,
        headers: [String: String] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeAll { $0.substring == substring }
        stubs.append(
            (substring,
                Stub(
                    status: status, body: body, headers: headers,
                    connectionError: false, hang: false)))
    }

    static func respondOnce(containing substring: String, status: Int, body: String) {
        lock.lock()
        defer { lock.unlock() }
        onceStubs.append(
            (substring,
                Stub(
                    status: status, body: body, headers: [:],
                    connectionError: false, hang: false)))
    }

    static func failWithConnectionError(containing substring: String) {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeAll { $0.substring == substring }
        stubs.append(
            (substring,
                Stub(
                    status: 0, body: "", headers: [:], connectionError: true,
                    hang: false)))
    }

    /// Never responds — the request timeout is what ends it.
    static func hang(containing substring: String) {
        lock.lock()
        defer { lock.unlock() }
        stubs.removeAll { $0.substring == substring }
        stubs.append(
            (substring,
                Stub(
                    status: 0, body: "", headers: [:], connectionError: false,
                    hang: true)))
    }

    static func requestCount(containing substring: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter { $0.path.contains(substring) }.count
    }

    /// Header value on the most recent matching request (nil when absent).
    static func lastHeader(_ name: String, containing substring: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last { $0.path.contains(substring) }?.headers[name]
    }

    /// Path+query of the most recent matching request.
    static func lastPath(containing substring: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last { $0.path.contains(substring) }?.path
    }

    /// JSON body of the most recent matching request.
    static func lastBody(containing substring: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last { $0.path.contains(substring) }?.body
    }

    private static func record(path: String, headers: [String: String], body: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Recorded(path: path, headers: headers, body: body))
    }

    /// URLSession hands URLProtocol an upload body as a stream, not
    /// `httpBody` — read whichever is present.
    private func capturedBody() -> String {
        if let data = request.httpBody {
            return String(decoding: data, as: UTF8.self)
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func match(_ path: String) -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        if let index = onceStubs.firstIndex(where: { path.contains($0.substring) }) {
            return onceStubs.remove(at: index).stub
        }
        return stubs.first { path.contains($0.substring) }?.stub
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        // Recorded WITH the query string so tests can assert query items;
        // stub matching stays on the bare path.
        let pathAndQuery = (request.url?.query).map { "\(path)?\($0)" } ?? path
        Self.record(
            path: pathAndQuery, headers: request.allHTTPHeaderFields ?? [:],
            body: capturedBody())
        guard let stub = Self.match(path) else {
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: 404, httpVersion: nil,
                    headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"no stub"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if stub.hang { return }
        if stub.connectionError {
            client?.urlProtocol(
                self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var headerFields = stub.headers
        headerFields["Content-Type"] = "application/json"
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: stub.status, httpVersion: nil,
                headerFields: headerFields)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
