import Foundation
import XCTest

@testable import Revnix

final class PreviewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    static let token = String(repeating: "a", count: 64)
    static let previewURL = URL(
        string: "voigu://revnix-preview?revnix_preview=\(token)")!

    static let previewBody = """
        {"placementKey":"revnix_preview","revision":null,"offering":null,\
        "paywall":{"paywallId":"pw_preview","name":"Preview",\
        "config":{"template":"minimal","headline":"h","ctaLabel":"Buy"}},\
        "experiment":null,"targeting":null,"preview":true,"expiresAt":1800000000000}
        """

    static func triggerBody(placement: String) -> String {
        """
        {"skipReason":null,"recorded":true,"status":"ok",\
        "placementKey":"\(placement)","revision":1,\
        "offering":{"offeringId":"off_1","displayName":"D","packages":[]},\
        "paywall":{"paywallId":"pw_1","name":"N",\
        "config":{"template":"minimal","headline":"h","ctaLabel":"Buy"}}}
        """
    }

    private func makeClient(
        onImplicitPaywall: @escaping @Sendable (RevnixImplicitTrigger) -> Void
    ) -> RevnixClient {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        return RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: MemoryStorage(),
                session: URLSession(configuration: sessionConfig),
                device: nil,
                onImplicitPaywall: onImplicitPaywall,
                lifecycle: .disabled))
    }

    func testPreviewLinkFetchesPreviewAndHandsItToTheHandlerNeverTriggering() async throws {
        StubProtocol.respond(
            containing: "/v1/config", status: 200, body: #"{"implicitPlacements":["deeplink_open"]}"#)
        StubProtocol.respond(
            containing: "/v1/placements/triggered", status: 200,
            body: Self.triggerBody(placement: "deeplink_open"))
        StubProtocol.respond(
            containing: "/v1/paywalls/preview/\(Self.token)", status: 200, body: Self.previewBody)
        let recorder = Recorder()
        let client = makeClient { trigger in recorder.record(trigger.resolution.placementKey) }

        await client.handleDeepLink(Self.previewURL)

        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/paywalls/preview/\(Self.token)"), 1)
        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/placements/triggered"), 0)
        XCTAssertEqual(recorder.values, ["revnix_preview"])
    }

    func testPreviewResolutionDecodesNullRevisionAndAbsentStatus() async throws {
        StubProtocol.respond(
            containing: "/v1/paywalls/preview/\(Self.token)", status: 200, body: Self.previewBody)
        let recorder = ResolutionRecorder()
        let client = makeClient { trigger in recorder.record(trigger.resolution) }

        await client.handleDeepLink(Self.previewURL)

        let resolution = try XCTUnwrap(recorder.values.first)
        XCTAssertEqual(resolution.status, "ok")
        XCTAssertEqual(resolution.revision, 0)
        XCTAssertEqual(resolution.preview, true)
        XCTAssertEqual(resolution.paywall?.paywallId, "pw_preview")
    }

    func testMalformedTokenFallsThroughToTheOrdinaryDeepLinkPath() async throws {
        StubProtocol.respond(
            containing: "/v1/config", status: 200, body: #"{"implicitPlacements":["deeplink_open"]}"#)
        StubProtocol.respond(
            containing: "/v1/placements/triggered", status: 200,
            body: Self.triggerBody(placement: "deeplink_open"))
        let recorder = Recorder()
        let client = makeClient { trigger in recorder.record(trigger.resolution.placementKey) }

        await client.handleDeepLink(
            URL(string: "voigu://revnix-preview?revnix_preview=not-hex")!)

        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/paywalls/preview/"), 0)
        XCTAssertEqual(recorder.values, ["deeplink_open"])
    }

    func testAnOrdinaryURLIsUnaffected() async throws {
        StubProtocol.respond(
            containing: "/v1/config", status: 200, body: #"{"implicitPlacements":["deeplink_open"]}"#)
        StubProtocol.respond(
            containing: "/v1/placements/triggered", status: 200,
            body: Self.triggerBody(placement: "deeplink_open"))
        let recorder = Recorder()
        let client = makeClient { trigger in recorder.record(trigger.resolution.placementKey) }

        await client.handleDeepLink(URL(string: "https://example.com/promo")!)

        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/paywalls/preview/"), 0)
        XCTAssertEqual(recorder.values, ["deeplink_open"])
    }

    func testA404NeverThrowsAndNeverPresents() async throws {
        StubProtocol.respond(
            containing: "/v1/paywalls/preview/\(Self.token)", status: 404,
            body: #"{"error":"not found"}"#)
        let recorder = Recorder()
        let client = makeClient { trigger in recorder.record(trigger.resolution.placementKey) }

        await client.handleDeepLink(Self.previewURL)

        XCTAssertEqual(recorder.values, [])
    }

    func testNoHandlerConfiguredNothingToPresentReportedViaOnDiagnostic() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        StubProtocol.respond(
            containing: "/v1/paywalls/preview/\(Self.token)", status: 200, body: Self.previewBody)
        let ops = Recorder()
        let client = RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: MemoryStorage(),
                onDiagnostic: { ops.record($0.op) },
                session: URLSession(configuration: sessionConfig),
                device: nil,
                implicitPlacements: true,
                lifecycle: .disabled))

        await client.handleDeepLink(Self.previewURL)

        XCTAssertTrue(ops.values.contains("preview"))
    }

    func testLogPaywallShownWithThePreviewKeySendsNoRequest() async throws {
        let client = makeClient { _ in }
        _ = await client.logPaywallShown(
            placementKey: revnixPreviewPlacementKey, paywallId: "pw_preview")
        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/paywalls/viewed"), 0)
    }

    func testLogPaywallClosedWithThePreviewKeySendsNoRequestOrDeclineTrigger() async throws {
        let recorder = Recorder()
        let client = makeClient { trigger in recorder.record(trigger.resolution.placementKey) }
        await client.logPaywallClosed(
            viewId: "v1", placementKey: revnixPreviewPlacementKey, paywallId: "pw_preview")
        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/paywalls/closed"), 0)
        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/placements/triggered"), 0)
        XCTAssertEqual(recorder.values, [])
    }

    func testLogPaywallEventWithThePreviewKeySendsNoRequest() async throws {
        let client = makeClient { _ in }
        await client.logPaywallEvent(
            .purchaseAbandoned, viewId: "v1", placementKey: revnixPreviewPlacementKey,
            paywallId: "pw_preview")
        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/paywalls/events"), 0)
        XCTAssertEqual(StubProtocol.requestCount(containing: "/v1/placements/triggered"), 0)
    }

    func testColdStartPreviewPresentedAfterTheLaunchBatch() async throws {
        StubProtocol.respond(
            containing: "/v1/config", status: 200, body: #"{"implicitPlacements":["app_launch"]}"#)
        StubProtocol.hang(containing: "/v1/placements/triggered")
        StubProtocol.respond(
            containing: "/v1/paywalls/preview/\(Self.token)", status: 200, body: Self.previewBody)

        let events = Recorder()
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        let client = RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: MemoryStorage(),
                timeout: 0.3,
                onDiagnostic: { events.record($0.op) },
                session: URLSession(configuration: sessionConfig),
                device: nil,
                onImplicitPaywall: { trigger in events.record(trigger.resolution.placementKey) },
                lifecycle: .disabled))

        var waited = 0
        while StubProtocol.requestCount(containing: "/v1/placements/triggered") == 0 {
            waited += 1
            guard waited < 200 else { return XCTFail("app_launch never reached the server") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await client.handleDeepLink(Self.previewURL)

        XCTAssertEqual(events.values, ["implicit:app_launch", "revnix_preview"])
    }
}

final class ResolutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PlacementResolution] = []
    func record(_ item: PlacementResolution) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }
    var values: [PlacementResolution] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
