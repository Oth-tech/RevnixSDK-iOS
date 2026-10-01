import Foundation
import XCTest
import os

@testable import Revnix

final class TrackingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        StubProtocol.respond(containing: "/attributes", status: 200, body: "{}")
        StubProtocol.respond(containing: "/installs", status: 200, body: "{}")
    }

    private func makeClient(
        attWaitTimeout: TimeInterval? = nil,
        onDiagnostic: (@Sendable (RevnixDiagnostic) -> Void)? = nil
    ) -> RevnixClient {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        return RevnixClient(
            RevnixConfig(
                apiKey: "rvx_pk_test_abc",
                baseURL: URL(string: "https://example.convex.site")!,
                storage: MemoryStorage(),
                onDiagnostic: onDiagnostic,
                session: URLSession(configuration: sessionConfig),
                device: nil,
                lifecycle: .disabled,
                skan: false,
                attWaitTimeout: attWaitTimeout))
    }

    private func fake(
        _ status: OSAllocatedUnfairLock<Int>, idfa: String? = "AAAA-1111"
    ) -> RevnixTracking {
        RevnixTracking(
            status: { status.withLock { $0 } },
            request: { status.withLock { $0 } },
            idfa: { idfa })
    }

    func testAuthorizedStoresStatusAndIdfaOncePerCustomer() async throws {
        let client = makeClient()
        await client.setTracking(fake(OSAllocatedUnfairLock(initialState: 3)))

        let status = await client.requestTrackingAuthorization()

        XCTAssertEqual(status, 3)
        let body = try XCTUnwrap(StubProtocol.lastBody(containing: "/attributes"))
        XCTAssertTrue(body.contains(#""att_status":"authorized""#), body)
        XCTAssertTrue(body.contains(#""idfa":"AAAA-1111""#), body)

        _ = await client.requestTrackingAuthorization()
        XCTAssertEqual(StubProtocol.requestCount(containing: "/attributes"), 1)

        _ = await client.logout()
        _ = await client.requestTrackingAuthorization()
        XCTAssertEqual(StubProtocol.requestCount(containing: "/attributes"), 2)
    }

    func testDeniedStoresStatusAndRemovesIdfa() async throws {
        let client = makeClient()
        await client.setTracking(fake(OSAllocatedUnfairLock(initialState: 2)))

        let status = await client.requestTrackingAuthorization()

        XCTAssertEqual(status, 2)
        let body = try XCTUnwrap(StubProtocol.lastBody(containing: "/attributes"))
        XCTAssertTrue(body.contains(#""att_status":"denied""#), body)
        XCTAssertTrue(body.contains(#""idfa":null"#), body)
    }

    func testAuthorizedWithZeroedIdfaRemovesIt() async throws {
        let client = makeClient()
        await client.setTracking(fake(OSAllocatedUnfairLock(initialState: 3), idfa: nil))

        _ = await client.requestTrackingAuthorization()

        let body = try XCTUnwrap(StubProtocol.lastBody(containing: "/attributes"))
        XCTAssertTrue(body.contains(#""idfa":null"#), body)
    }

    func testNotDeterminedAndUnsupportedSendNothing() async {
        let client = makeClient()
        for raw in [0, -1] {
            await client.setTracking(fake(OSAllocatedUnfairLock(initialState: raw)))
            let status = await client.requestTrackingAuthorization()
            XCTAssertEqual(status, raw)
        }
        XCTAssertEqual(StubProtocol.requestCount(containing: "/attributes"), 0)
    }

    func testFailedStoreReportsDiagnosticAndRetriesNextCall() async {
        StubProtocol.respond(containing: "/attributes", status: 500, body: "{}")
        let ops = Recorder()
        let client = makeClient(onDiagnostic: { ops.record($0.op) })
        await client.setTracking(fake(OSAllocatedUnfairLock(initialState: 3)))

        _ = await client.requestTrackingAuthorization()
        XCTAssertTrue(ops.values.contains("requestTrackingAuthorization"))

        StubProtocol.respond(containing: "/attributes", status: 200, body: "{}")
        _ = await client.requestTrackingAuthorization()
        XCTAssertEqual(StubProtocol.requestCount(containing: "/attributes"), 2)
    }

    func testInstallWaitsForTheAnswerThenSendsIdfaFirst() async {
        let status = OSAllocatedUnfairLock(initialState: 0)
        let client = makeClient(attWaitTimeout: 5)
        await client.setTracking(fake(status))

        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            status.withLock { $0 = 3 }
        }
        await client.registerInstall()

        let paths = StubProtocol.paths()
        let attributes = paths.firstIndex { $0.contains("/attributes") }
        let install = paths.firstIndex { $0.contains("/installs") }
        XCTAssertNotNil(attributes)
        XCTAssertNotNil(install)
        XCTAssertLessThan(attributes ?? .max, install ?? .min)
    }

    func testInstallGivesUpAfterTheTimeout() async {
        let client = makeClient(attWaitTimeout: 0.3)
        await client.setTracking(fake(OSAllocatedUnfairLock(initialState: 0)))

        let started = Date()
        await client.registerInstall()

        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        XCTAssertEqual(StubProtocol.requestCount(containing: "/installs"), 1)
        XCTAssertEqual(StubProtocol.requestCount(containing: "/attributes"), 0)
    }

    func testInstallDoesNotWaitWithoutTheConfig() async {
        let client = makeClient()
        await client.setTracking(fake(OSAllocatedUnfairLock(initialState: 0)))

        let started = Date()
        await client.registerInstall()

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(StubProtocol.requestCount(containing: "/installs"), 1)
    }

    func testLaterInstallCallsPickUpARevokeFromSettings() async throws {
        let status = OSAllocatedUnfairLock(initialState: 3)
        let client = makeClient()
        await client.setTracking(fake(status))
        _ = await client.requestTrackingAuthorization()
        XCTAssertEqual(StubProtocol.requestCount(containing: "/attributes"), 1)

        status.withLock { $0 = 2 }
        await client.registerInstall()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(StubProtocol.requestCount(containing: "/attributes"), 2)
        let body = try XCTUnwrap(StubProtocol.lastBody(containing: "/attributes"))
        XCTAssertTrue(body.contains(#""att_status":"denied""#), body)
        XCTAssertTrue(body.contains(#""idfa":null"#), body)
    }

    func testInstallWithoutAnEarlierAnswerNeverWritesTracking() async throws {
        let client = makeClient()
        await client.setTracking(fake(OSAllocatedUnfairLock(initialState: 2)))

        await client.registerInstall()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(StubProtocol.requestCount(containing: "/attributes"), 0)
    }
}
