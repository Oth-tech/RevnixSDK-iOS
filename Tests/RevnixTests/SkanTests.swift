import Foundation
import XCTest

@testable import Revnix

/// Every test injects `setSkanUpdater`: the macOS test host has no
/// SKAdNetwork, so the real call can never run here.
final class SkanTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        StubProtocol.respond(containing: "/installs", status: 200, body: "{}")
    }

    private struct SkanError: Error {}

    private func makeClient(
        storage: RevnixStorage = MemoryStorage(),
        skan: Bool = true,
        onDiagnostic: (@Sendable (RevnixDiagnostic) -> Void)? = nil
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
                lifecycle: .disabled,
                skan: skan))
    }

    private func updater(_ calls: Recorder, failFirst: Bool = false) -> SkanUpdater {
        { value, coarse, lockWindow in
            calls.record("\(value)|\(coarse?.rawValue ?? "nil")|\(lockWindow)")
            if failFirst && calls.count == 1 {
                throw SkanError()
            }
        }
    }

    private func waitForCalls(_ calls: Recorder, count: Int) async throws {
        var waited = 0
        while calls.count < count {
            waited += 1
            guard waited < 200 else {
                return XCTFail("skan updater never reached \(count) call(s)")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitForNoFurtherSkanCalls() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testRegisterInstallArmsOnceWithZeroAndDoesNotArmAgain() async throws {
        let calls = Recorder()
        let client = makeClient()
        await client.setSkanUpdater(updater(calls))

        await client.registerInstall()
        try await waitForCalls(calls, count: 1)
        XCTAssertEqual(calls.values, ["0|nil|false"])

        await client.registerInstall()
        try await waitForNoFurtherSkanCalls()
        XCTAssertEqual(calls.values, ["0|nil|false"])
    }

    func testTheArmLatchSurvivesLogout() async throws {
        let calls = Recorder()
        let client = makeClient()
        await client.setSkanUpdater(updater(calls))

        await client.registerInstall()
        try await waitForCalls(calls, count: 1)
        _ = await client.logout()
        await client.registerInstall()
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(calls.values, ["0|nil|false"])
    }

    func testSkanDisabledReachesNeitherTheAutoArmNorTheExplicitUpdate() async throws {
        let calls = Recorder()
        let events = Recorder()
        let client = makeClient(skan: false, onDiagnostic: { events.record($0.op) })
        await client.setSkanUpdater(updater(calls))

        await client.registerInstall()
        await client.updateSkanConversionValue(7)
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(calls.count, 0)
        XCTAssertTrue(events.values.contains("updateSkanConversionValue"), "\(events.values)")
    }

    func testConversionValuesOutsideZeroToSixtyThreeAreRefused() async throws {
        let calls = Recorder()
        let events = Recorder()
        let client = makeClient(onDiagnostic: { events.record($0.op) })
        await client.setSkanUpdater(updater(calls))

        await client.updateSkanConversionValue(-1)
        await client.updateSkanConversionValue(64)
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(
            events.values, ["updateSkanConversionValue", "updateSkanConversionValue"])

        await client.updateSkanConversionValue(0)
        await client.updateSkanConversionValue(63)
        XCTAssertEqual(calls.values, ["0|nil|false", "63|nil|false"])
    }

    func testCoarseValueAndLockWindowArePassedThroughUnchanged() async throws {
        let calls = Recorder()
        let client = makeClient()
        await client.setSkanUpdater(updater(calls))

        await client.updateSkanConversionValue(12, coarse: .high, lockWindow: true)

        XCTAssertEqual(calls.values, ["12|high|true"])
    }

    func testAFailedArmDoesNotLatchAndRetriesOnTheNextRegisterInstall() async throws {
        let calls = Recorder()
        let events = Recorder()
        let storage = MemoryStorage()
        let client = makeClient(storage: storage, onDiagnostic: { events.record($0.op) })
        await client.setSkanUpdater(updater(calls, failFirst: true))

        await client.registerInstall()
        try await waitForCalls(calls, count: 1)
        XCTAssertNil(storage.get("revnix.skanRegistered"))

        await client.registerInstall()
        try await waitForCalls(calls, count: 2)
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(calls.values, ["0|nil|false", "0|nil|false"])
        XCTAssertTrue(events.values.contains("armSkan"), "\(events.values)")
        XCTAssertEqual(storage.get("revnix.skanRegistered"), "1")
    }

    func testAnInFlightConversionValueIsNotClobberedByTheArmingZero() async throws {
        let started = Recorder()
        let finished = Recorder()
        let client = makeClient()
        await client.setSkanUpdater { value, _, _ in
            started.record("\(value)")
            try? await Task.sleep(nanoseconds: 300_000_000)
            finished.record("\(value)")
        }

        async let update: Void = client.updateSkanConversionValue(30)
        try await waitForCalls(started, count: 1)
        await client.registerInstall()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(started.values, ["30"], "the auto-arm ran against an in-flight update")

        await update
        try await waitForNoFurtherSkanCalls()
        XCTAssertEqual(started.values, ["30"])
        XCTAssertEqual(finished.values, ["30"])
    }

    func testTwoOverlappingRegisterInstallsArmOnlyOnce() async throws {
        let calls = Recorder()
        let client = makeClient()
        await client.setSkanUpdater { value, _, _ in
            calls.record("\(value)")
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        async let first: Void = client.registerInstall()
        async let second: Void = client.registerInstall()
        _ = await (first, second)
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(calls.values, ["0"])
    }

    func testLockWindowWithoutACoarseValueWarnsAndStillSendsTheFineValue() async throws {
        let calls = Recorder()
        let events = Recorder()
        let client = makeClient(onDiagnostic: { events.record("\($0.op)|\($0.message)") })
        await client.setSkanUpdater(updater(calls))

        await client.updateSkanConversionValue(40, lockWindow: true)

        XCTAssertEqual(calls.values, ["40|nil|true"])
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events.values[0].hasPrefix("updateSkanConversionValue|"), "\(events.values)")
        XCTAssertTrue(events.values[0].contains("ignores lockWindow"), "\(events.values)")
    }

    func testTheAutoArmIsSilentWhereSkadnetworkDoesNotExist() async throws {
        try XCTSkipIf(RevnixSkan.isSupported)
        let events = Recorder()
        let storage = MemoryStorage()
        let client = makeClient(storage: storage, onDiagnostic: { events.record($0.op) })

        await client.registerInstall()
        try await waitForNoFurtherSkanCalls()
        await client.registerInstall()
        try await waitForNoFurtherSkanCalls()

        XCTAssertFalse(events.values.contains("armSkan"), "\(events.values)")
        XCTAssertNil(storage.get("revnix.skanRegistered"))
    }

    func testASuccessfulConversionValueUpdateLatchesSoRegisterInstallDoesNotArm() async throws {
        let calls = Recorder()
        let storage = MemoryStorage()
        let client = makeClient(storage: storage)
        await client.setSkanUpdater(updater(calls))

        await client.updateSkanConversionValue(5)
        XCTAssertEqual(storage.get("revnix.skanRegistered"), "1")

        await client.registerInstall()
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(calls.values, ["5|nil|false"])
    }

    func testAFailedArmDoesNotDeleteALatchWonByAConcurrentHostUpdate() async throws {
        let armStarted = Recorder()
        let release = Recorder()
        let calls = Recorder()
        let storage = MemoryStorage()
        let client = makeClient(storage: storage)
        await client.setSkanUpdater { value, _, _ in
            calls.record("\(value)")
            if value == 0 {
                armStarted.record("1")
                while release.count == 0 {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                throw SkanError()
            }
        }

        await client.registerInstall()
        try await waitForCalls(armStarted, count: 1)

        await client.updateSkanConversionValue(30)
        XCTAssertEqual(storage.get("revnix.skanRegistered"), "1")

        release.record("go")
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(storage.get("revnix.skanRegistered"), "1")

        await client.registerInstall()
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(calls.values, ["0", "30"])
    }

    func testManagedSkanFromTheServerIsAppliedAfterTheArm() async throws {
        StubProtocol.respond(
            containing: "/skan", status: 200, body: #"{"managed":true,"fine":12,"coarse":"high"}"#)
        let calls = Recorder()
        let client = makeClient()
        await client.setSkanUpdater(updater(calls))

        await client.registerInstall()
        try await waitForCalls(calls, count: 2)

        XCTAssertEqual(calls.values, ["0|nil|false", "12|high|false"])
    }

    func testUnmanagedSkanAppliesNothing() async throws {
        StubProtocol.respond(containing: "/skan", status: 200, body: #"{"managed":false}"#)
        let calls = Recorder()
        let client = makeClient()
        await client.setSkanUpdater(updater(calls))

        await client.registerInstall()
        try await waitForCalls(calls, count: 1)
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(calls.values, ["0|nil|false"])
    }

    func testTheSameManagedValueIsAppliedOnlyOnce() async throws {
        StubProtocol.respond(
            containing: "/skan", status: 200, body: #"{"managed":true,"fine":12,"coarse":"high"}"#)
        let calls = Recorder()
        let client = makeClient()
        await client.setSkanUpdater(updater(calls))

        await client.registerInstall()
        try await waitForCalls(calls, count: 2)
        await client.registerInstall()
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(calls.values, ["0|nil|false", "12|high|false"])
        XCTAssertEqual(StubProtocol.requestCount(containing: "/skan"), 2)
    }

    func testAFailedArmLatchesViaASuccessfulManagedSyncAndDoesNotResendZero() async throws {
        StubProtocol.respond(
            containing: "/skan", status: 200, body: #"{"managed":true,"fine":12,"coarse":"high"}"#)
        let calls = Recorder()
        let client = makeClient()
        await client.setSkanUpdater(updater(calls, failFirst: true))

        await client.registerInstall()
        try await waitForCalls(calls, count: 2)
        XCTAssertEqual(calls.values, ["0|nil|false", "12|high|false"])

        await client.registerInstall()
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(
            calls.values, ["0|nil|false", "12|high|false"],
            "the second launch resent the arming zero instead of staying latched")
    }

    func testSkanSyncStopsThirtyFiveDaysAfterTheFirstSync() async throws {
        let storage = MemoryStorage()
        let longAgo = Int(Date().timeIntervalSince1970) - 36 * 24 * 3600
        storage.set("revnix.skanFirstSyncAt", String(longAgo))
        StubProtocol.respond(
            containing: "/skan", status: 200, body: #"{"managed":true,"fine":12,"coarse":"high"}"#)
        let calls = Recorder()
        let client = makeClient(storage: storage)
        await client.setSkanUpdater(updater(calls))

        await client.registerInstall()
        try await waitForCalls(calls, count: 1)
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(calls.values, ["0|nil|false"])
        XCTAssertEqual(StubProtocol.requestCount(containing: "/skan"), 0)
    }

    func testSkanDisabledNeverSyncsManagedValues() async throws {
        StubProtocol.respond(
            containing: "/skan", status: 200, body: #"{"managed":true,"fine":12,"coarse":"high"}"#)
        let calls = Recorder()
        let client = makeClient(skan: false)
        await client.setSkanUpdater(updater(calls))

        await client.registerInstall()
        try await waitForNoFurtherSkanCalls()

        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(StubProtocol.requestCount(containing: "/skan"), 0)
    }
}
