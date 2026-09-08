import XCTest

@testable import Revnix

/// REV-272: the implicit placement contract, iOS side.
///
/// The server 400s a key it does not know, and the failure is SILENT from the
/// app's side — the moment simply never fires and nobody sees a paywall that
/// was configured. That makes the key spellings the one thing here worth
/// asserting hard, alongside the loop guard's shape.
final class ImplicitPlacementTests: XCTestCase {

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
}
