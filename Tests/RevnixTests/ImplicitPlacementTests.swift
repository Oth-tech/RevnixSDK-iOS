import Foundation
import XCTest

@testable import Revnix

/// REV-272: the implicit placement contract, iOS side.
///
/// The server 400s a key it does not know, and the failure is SILENT from the
/// app's side — the moment simply never fires and nobody sees a paywall that
/// was configured. That makes the key spellings the one thing here worth
/// asserting hard, alongside the loop guard's shape.
final class ImplicitPlacementTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    func testSixKeysMatchTheServerContract() {
        XCTAssertEqual(
            RevnixImplicitPlacement.allCases.map(\.rawValue),
            [
                "app_install",
                "app_launch",
                "session_start",
                "deeplink_open",
                "paywall_decline",
                "transaction_abandon",
            ])
    }

    func testEveryKeyIsOneTheCatalogWouldAccept() {
        // A placement key must match ^[a-z0-9][a-z0-9._-]{0,63}$ server-side.
        // This is why the deep link moment is `deeplink_open` and not
        // Superwall's `deepLink_open` — the capital L could never be stored.
        let pattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9._-]{0,63}$")
        for placement in RevnixImplicitPlacement.allCases {
            let key = placement.rawValue
            let range = NSRange(key.startIndex..., in: key)
            XCTAssertNotNil(
                pattern.firstMatch(in: key, range: range),
                "\(key) would be refused by the catalog")
        }
        let bad = "deepLink_open"
        XCTAssertNil(
            pattern.firstMatch(in: bad, range: NSRange(bad.startIndex..., in: bad)))
    }

    func testImplicitPlacementsAreOffUntilAHandlerIsGiven() {
        // The default has to be free: without a handler there is nothing to do
        // with a resolved paywall, and asking /v1/config for the whole fleet is
        // exactly the cost this feature is designed to avoid.
        let url = URL(string: "https://x.convex.site")!
        let base = RevnixConfig(apiKey: "rvx_pk_test", baseURL: url)
        XCTAssertFalse(base.implicitPlacementsEnabled)
        XCTAssertEqual(base.sessionTimeout, 30 * 60)

        let opted = RevnixConfig(apiKey: "rvx_pk_test", baseURL: url, onImplicitPaywall: { _ in })
        XCTAssertTrue(opted.implicitPlacementsEnabled)

        // The explicit switch wins over a handler, in both directions.
        let off = RevnixConfig(
            apiKey: "rvx_pk_test", baseURL: url,
            onImplicitPaywall: { _ in }, implicitPlacements: false)
        XCTAssertFalse(off.implicitPlacementsEnabled)
        let on = RevnixConfig(apiKey: "rvx_pk_test", baseURL: url, implicitPlacements: true)
        XCTAssertTrue(on.implicitPlacementsEnabled)
    }

    func testDisabledLifecycleSubscribesToNothing() {
        var fired = 0
        let cancel = RevnixAppLifecycle.disabled.onStateChange { _ in fired += 1 }
        cancel()
        XCTAssertEqual(fired, 0)
    }

    func testAnInjectedLifecycleReportsBothStatesAndIsCancellable() {
        // Both transitions matter: a session is defined by time in the
        // BACKGROUND, which foreground events alone cannot measure.
        var handler: ((RevnixAppState) -> Void)?
        let lifecycle = RevnixAppLifecycle { h in
            handler = h
            return { handler = nil }
        }
        var seen: [RevnixAppState] = []
        let cancel = lifecycle.onStateChange { seen.append($0) }
        handler?(.background)
        handler?(.foreground)
        XCTAssertEqual(seen, [.background, .foreground])
        cancel()
        XCTAssertNil(handler)
    }

    func testNoHandlerStillReportsTheDeepLinkWithResolveFalseAndAsksNoConfig() async throws {
        StubProtocol.respond(
            containing: "/v1/placements/triggered", status: 200,
            body: PreviewTests.triggerBody(placement: "deeplink_open"))
        let client = RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: MemoryStorage(),
                session: URLSession(configuration: {
                    let config = URLSessionConfiguration.ephemeral
                    config.protocolClasses = [StubProtocol.self]
                    return config
                }()),
                device: nil,
                lifecycle: .disabled))

        await client.handleDeepLink(URL(string: "https://example.com/promo?utm_source=ig")!)

        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/placements/triggered"), 1)
        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/config"), 0)
        XCTAssertEqual(
            try XCTUnwrap(StubProtocol.lastBody(containing: "/v1/placements/triggered"))
                .contains(#""resolve":false"#), true)
    }

    func testImplicitPlacementsOffNeverPresentsADeepLinkPaywallEvenWithAHandler() async throws {
        StubProtocol.respond(
            containing: "/v1/placements/triggered", status: 200,
            body: PreviewTests.triggerBody(placement: "deeplink_open"))
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        let recorder = Recorder()
        let client = RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: MemoryStorage(),
                session: URLSession(configuration: sessionConfig),
                device: nil,
                onImplicitPaywall: { trigger in recorder.record(trigger.resolution.placementKey) },
                implicitPlacements: false,
                lifecycle: .disabled))

        await client.handleDeepLink(URL(string: "https://example.com/promo?utm_source=ig")!)

        XCTAssertEqual(recorder.values, [])
        XCTAssertEqual(
            try XCTUnwrap(StubProtocol.lastBody(containing: "/v1/placements/triggered"))
                .contains(#""resolve":false"#), true)
    }

    func testDeeplinkOpenNotConfiguredStillReportsButNeverResolvesForThatPlacement() async throws {
        StubProtocol.respond(
            containing: "/v1/config", status: 200, body: #"{"implicitPlacements":["paywall_decline"]}"#)
        StubProtocol.respond(
            containing: "/v1/placements/triggered", status: 200,
            body: PreviewTests.triggerBody(placement: "deeplink_open"))
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        let recorder = Recorder()
        let client = RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: MemoryStorage(),
                session: URLSession(configuration: sessionConfig),
                device: nil,
                onImplicitPaywall: { trigger in recorder.record(trigger.resolution.placementKey) },
                lifecycle: .disabled))

        await client.handleDeepLink(URL(string: "https://example.com/promo?utm_source=ig")!)

        XCTAssertEqual(recorder.values, [])
        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/placements/triggered"), 1)
        XCTAssertEqual(
            try XCTUnwrap(StubProtocol.lastBody(containing: "/v1/placements/triggered"))
                .contains(#""resolve":false"#), true)
    }

    func testSessionStartCarriesThePreviousSessionLength() async throws {
        StubProtocol.respond(
            containing: "/v1/config", status: 200,
            body: #"{"implicitPlacements":["session_start"]}"#)
        StubProtocol.respond(
            containing: "/v1/placements/triggered", status: 200,
            body: PreviewTests.triggerBody(placement: "session_start"))
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var clockNow = t0
        var handler: ((RevnixAppState) -> Void)?
        let lifecycle = RevnixAppLifecycle { h in
            handler = h
            return { handler = nil }
        }
        let client = RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: MemoryStorage(),
                now: { clockNow },
                session: URLSession(configuration: {
                    let config = URLSessionConfiguration.ephemeral
                    config.protocolClasses = [StubProtocol.self]
                    return config
                }()),
                device: nil,
                implicitPlacements: true,
                lifecycle: lifecycle))

        await client.stop()
        await client.start()
        XCTAssertEqual(
            try XCTUnwrap(StubProtocol.lastBody(containing: "/v1/placements/triggered"))
                .contains("previousSessionMs"), false)

        clockNow = t0.addingTimeInterval(10 * 60)
        handler?(.background)
        try await Task.sleep(nanoseconds: 50_000_000)

        clockNow = t0.addingTimeInterval(10 * 60 + 31 * 60)
        handler?(.foreground)
        try await Task.sleep(nanoseconds: 50_000_000)

        let body = try XCTUnwrap(StubProtocol.lastBody(containing: "/v1/placements/triggered"))
        XCTAssertTrue(body.contains(#""previousSessionMs":600000"#), body)
    }

    func testSessionStartAcrossAColdStartReadsThePriorClientsBackground() async throws {
        StubProtocol.respond(
            containing: "/v1/config", status: 200,
            body: #"{"implicitPlacements":["session_start"]}"#)
        StubProtocol.respond(
            containing: "/v1/placements/triggered", status: 200,
            body: PreviewTests.triggerBody(placement: "session_start"))
        let storage = MemoryStorage()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var clockNow = t0
        var handlerA: ((RevnixAppState) -> Void)?
        let lifecycleA = RevnixAppLifecycle { h in
            handlerA = h
            return { handlerA = nil }
        }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        let clientA = RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: storage,
                now: { clockNow },
                session: URLSession(configuration: sessionConfig),
                device: nil,
                implicitPlacements: true,
                lifecycle: lifecycleA))
        await clientA.stop()
        await clientA.start()

        clockNow = t0.addingTimeInterval(5 * 60)
        handlerA?(.background)
        try await Task.sleep(nanoseconds: 50_000_000)

        clockNow = t0.addingTimeInterval(2 * 3600)
        let clientB = RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: storage,
                now: { clockNow },
                session: URLSession(configuration: sessionConfig),
                device: nil,
                implicitPlacements: true,
                lifecycle: .disabled))
        await clientB.stop()
        await clientB.start()

        let body = try XCTUnwrap(StubProtocol.lastBody(containing: "/v1/placements/triggered"))
        XCTAssertTrue(body.contains(#""previousSessionMs":300000"#), body)
    }

    func testStopThenStartClearsTheStoppedFlagSoADeepLinkIsReportedAgain() async throws {
        StubProtocol.respond(
            containing: "/v1/placements/triggered", status: 200,
            body: PreviewTests.triggerBody(placement: "deeplink_open"))
        let client = RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: MemoryStorage(),
                session: URLSession(configuration: {
                    let config = URLSessionConfiguration.ephemeral
                    config.protocolClasses = [StubProtocol.self]
                    return config
                }()),
                device: nil,
                lifecycle: .disabled))

        await client.stop()
        await client.start()
        await client.handleDeepLink(URL(string: "https://example.com/promo?utm_source=ig")!)

        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/placements/triggered"), 1)
    }
}
