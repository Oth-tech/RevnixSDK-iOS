import Foundation
import XCTest

@testable import Revnix

final class AttributionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    static let clickVerdict = """
        {"installMatch":"click","attributedAt":1700000000000,"linkToken":"lnk_1","matchSignals":["ip","os"],"source":"instagram","medium":"cpc","campaign":"summer"}
        """

    static let reattributedVerdict = """
        {"installMatch":"referrer","attributedAt":1700000000000,"reattributedAt":1700000900000,"referrerSource":"play"}
        """

    private func makeClient(
        storage: RevnixStorage = MemoryStorage(),
        onDiagnostic: (@Sendable (RevnixDiagnostic) -> Void)? = nil,
        onAttribution: (@Sendable (RevnixAttribution) -> Void)? = nil
    ) -> RevnixClient {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        return RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: storage,
                onDiagnostic: onDiagnostic,
                session: URLSession(configuration: sessionConfig),
                device: nil,
                onAttribution: onAttribution,
                lifecycle: .disabled))
    }

    private func waitForAttributionRequests(_ count: Int) async throws {
        var waited = 0
        while StubProtocol.requestCount(containing: "/attribution") < count {
            waited += 1
            guard waited < 200 else {
                return XCTFail("the verdict was never fetched \(count) time(s)")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testVerdictIsDecodedAndReturned() async throws {
        StubProtocol.respond(containing: "/attribution", status: 200, body: Self.clickVerdict)
        let storage = MemoryStorage()
        let client = makeClient(storage: storage)

        let result = await client.getAttribution()

        let attribution = try XCTUnwrap(result)
        XCTAssertEqual(attribution.installMatch, "click")
        XCTAssertEqual(attribution.attributedAt, 1_700_000_000_000)
        XCTAssertEqual(attribution.linkToken, "lnk_1")
        XCTAssertEqual(attribution.matchSignals, ["ip", "os"])
        XCTAssertEqual(attribution.source, "instagram")
        XCTAssertEqual(attribution.medium, "cpc")
        XCTAssertEqual(attribution.campaign, "summer")
        XCTAssertNil(attribution.reattributedAt)
        XCTAssertNil(attribution.term)
        let cid = storage.get("revnix.customerId") ?? ""
        XCTAssertEqual(
            StubProtocol.lastPath(containing: "/attribution"),
            "/v1/customers/\(cid)/attribution")
    }

    func testUnknownReadsAsNilWithoutADiagnosticOrACallback() async throws {
        StubProtocol.respond(
            containing: "/attribution", status: 200, body: #"{"installMatch":"unknown"}"#)
        let events = Recorder()
        let fired = Recorder()
        let client = makeClient(
            onDiagnostic: { events.record($0.op) },
            onAttribution: { _ in fired.record("fired") })

        let result = await client.getAttribution()

        XCTAssertNil(result)
        XCTAssertEqual(events.count, 0)
        XCTAssertEqual(fired.count, 0)
    }

    func testATransportFailureReadsAsNilAndReportsADiagnostic() async throws {
        StubProtocol.failWithConnectionError(containing: "/attribution")
        let events = Recorder()
        let client = makeClient(onDiagnostic: { events.record($0.op) })

        let result = await client.getAttribution()

        XCTAssertNil(result)
        XCTAssertEqual(events.values, ["getAttribution"])
    }

    func testAMalformedVerdictReadsAsNilAndReportsADiagnostic() async throws {
        StubProtocol.respond(containing: "/attribution", status: 200, body: "not json")
        let events = Recorder()
        let client = makeClient(onDiagnostic: { events.record($0.op) })

        let result = await client.getAttribution()

        XCTAssertNil(result)
        XCTAssertEqual(events.values, ["getAttribution"])
    }

    func testTheHandlerFiresOnceAndNotAgainForAnIdenticalVerdict() async throws {
        StubProtocol.respond(containing: "/attribution", status: 200, body: Self.clickVerdict)
        let fired = Recorder()
        let client = makeClient(onAttribution: { fired.record($0.installMatch) })

        _ = await client.getAttribution()
        _ = await client.getAttribution()

        XCTAssertEqual(fired.values, ["click"])
    }

    func testTheHandlerFiresAgainWhenTheVerdictChanges() async throws {
        StubProtocol.respond(containing: "/attribution", status: 200, body: Self.clickVerdict)
        let fired = Recorder()
        let client = makeClient(onAttribution: { fired.record($0.installMatch) })

        _ = await client.getAttribution()
        StubProtocol.respond(
            containing: "/attribution", status: 200, body: Self.reattributedVerdict)
        let second = await client.getAttribution()

        XCTAssertEqual(fired.values, ["click", "referrer"])
        XCTAssertEqual(second?.reattributedAt, 1_700_000_900_000)
        XCTAssertEqual(second?.referrerSource, "play")
    }

    func testAVerdictAlreadyCachedOnTheDeviceDoesNotFireAgainOnARelaunch() async throws {
        StubProtocol.respond(containing: "/attribution", status: 200, body: Self.clickVerdict)
        let storage = MemoryStorage()
        let fired = Recorder()
        _ = await makeClient(storage: storage, onAttribution: { _ in fired.record("first") })
            .getAttribution()

        _ = await makeClient(storage: storage, onAttribution: { _ in fired.record("second") })
            .getAttribution()

        XCTAssertEqual(fired.values, ["first"])
        XCTAssertNotNil(storage.get("revnix.attribution"))
    }

    func testInstallReportDoesNotFetchTheVerdictWithoutAHandler() async throws {
        StubProtocol.respond(containing: "/installs", status: 200, body: "{}")
        StubProtocol.respond(containing: "/attribution", status: 200, body: Self.clickVerdict)
        let client = makeClient()

        await client.registerInstall()
        try await settle()

        XCTAssertEqual(StubProtocol.requestCount(containing: "/attribution"), 0)
    }

    func testInstallReportFetchesTheVerdictExactlyOnceWithAHandler() async throws {
        StubProtocol.respond(containing: "/installs", status: 200, body: "{}")
        StubProtocol.respond(containing: "/attribution", status: 200, body: Self.clickVerdict)
        let storage = MemoryStorage()
        let fired = Recorder()
        let client = makeClient(storage: storage, onAttribution: { _ in fired.record("fired") })
        storage.set("revnix.appleSearchAds.\(await client.customerId())", "1")

        await client.registerInstall()
        try await waitForAttributionRequests(1)
        try await settle()

        XCTAssertEqual(StubProtocol.requestCount(containing: "/attribution"), 1)
        XCTAssertEqual(fired.count, 1)
    }

    func testTheSearchAdsReportFetchesTheVerdict() async throws {
        StubProtocol.respond(
            containing: "/installs", status: 200, body: #"{"appleAttribution":"resolved"}"#)
        StubProtocol.respond(containing: "/attribution", status: 200, body: Self.clickVerdict)
        let fired = Recorder()
        let client = makeClient(onAttribution: { _ in fired.record("fired") })

        await client.collectAppleSearchAdsAttribution(tokenOverride: { "tok_abc" })
        try await waitForAttributionRequests(1)
        try await settle()

        XCTAssertEqual(StubProtocol.requestCount(containing: "/attribution"), 1)
        XCTAssertEqual(fired.count, 1)
    }

    func testAFailedRefreshNeverReachesTheHandler() async throws {
        StubProtocol.respond(containing: "/installs", status: 200, body: "{}")
        StubProtocol.failWithConnectionError(containing: "/attribution")
        let events = Recorder()
        let fired = Recorder()
        let client = makeClient(
            onDiagnostic: { events.record($0.op) },
            onAttribution: { _ in fired.record("fired") })

        await client.registerInstall()
        try await waitForAttributionRequests(1)
        try await settle()

        XCTAssertEqual(fired.count, 0)
        XCTAssertTrue(events.values.contains("getAttribution"), "\(events.values)")
    }
}
