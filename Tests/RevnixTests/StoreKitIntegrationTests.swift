import Foundation
import XCTest

@testable import Revnix

#if canImport(StoreKitTest)
    import StoreKit
    import StoreKitTest

    /// Store-glue integration: a REAL StoreKit 2 purchase against the bundled
    /// `Revnix.storekit` configuration, driven through `RevnixStoreKit` with
    /// the network stubbed. What these assert is the part unit tests cannot —
    /// that the glue maps StoreKit's transaction onto the wire contract
    /// correctly, and that the JWS proof actually leaves the device.
    ///
    /// `SKTestSession` needs a host application on some platforms; when it is
    /// unavailable the suite skips rather than fails, so `swift test` stays
    /// green on machines/CI that cannot host it. Run in Xcode against an iOS
    /// simulator target for the full path.
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    final class StoreKitIntegrationTests: XCTestCase {

        private var session: SKTestSession!

        override func setUpWithError() throws {
            try super.setUpWithError()
            StubProtocol.reset()
            // SPM ships test resources in Bundle.module, not Bundle.main, so
            // the name-based initializer cannot find the configuration.
            guard
                let url = Bundle.module.url(
                    forResource: "Revnix", withExtension: "storekit")
            else {
                throw XCTSkip("Revnix.storekit missing from the test bundle")
            }
            do {
                session = try SKTestSession(contentsOf: url)
            } catch {
                throw XCTSkip(
                    "SKTestSession unavailable in this environment: \(error)")
            }
            session.disableDialogs = true
            session.clearTransactions()
        }

        override func tearDown() {
            session?.clearTransactions()
            session = nil
            super.tearDown()
        }

        /// StoreKit 2 resolves products against the host application's bundle.
        /// A headless `swift test` process has no app bundle, so the store
        /// returns nothing there — skip with a precise reason rather than
        /// failing. Under an Xcode scheme with a host app (iOS simulator) the
        /// products resolve and the whole suite runs for real.
        private func product(_ id: String) async throws -> Product {
            let products = try await Product.products(for: [id])
            guard let product = products.first else {
                throw XCTSkip(
                    """
                    StoreKit returned no products for \(id) — this process has \
                    no host app bundle. Run this suite from Xcode against a \
                    simulator target with Revnix.storekit selected in the scheme.
                    """)
            }
            return product
        }

        private func makeClient(storage: RevnixStorage = MemoryStorage())
            -> RevnixClient
        {
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.protocolClasses = [StubProtocol.self]
            return RevnixClient(
                RevnixConfig(
                    apiKey: "rvx_pk_test_abc",
                    baseURL: URL(string: "https://example.convex.site")!,
                    storage: storage,
                    entitlementsTTL: 0,
                    session: URLSession(configuration: sessionConfig)
                ))
        }

        /// tap → StoreKit purchase → registerPurchase WITH JWS proof → the
        /// ledger cursor catches up → the gate is open. One call, no polling
        /// by the app.
        func testPurchaseRegistersWithProofAndUnlocksTheGate() async throws {
            StubProtocol.respond(
                containing: "/purchases", status: 201,
                body: """
                    {"eventId":"evt_1","seq":9,"duplicate":false,"customerId":"cust_1","transferred":false,"provisional":false}
                    """)
            StubProtocol.respond(
                containing: "/entitlements", status: 200,
                body: """
                    {"customerId":"cust_1","cursor":9,"entitlements":[{"entitlementId":"pro","isActive":true,"expiresAt":4102444800000,"sources":[]}]}
                    """)

            let client = makeClient()
            let product = try await self.product("pro.monthly")

            let result = try await RevnixStoreKit.purchase(product, client: client)
            let registered = try XCTUnwrap(result, "purchase did not register")
            XCTAssertEqual(registered.seq, 9)
            XCTAssertEqual(registered.provisional, false)

            // The proof path: the JWS must be on the wire, or the server can
            // only record a provisional claim.
            let body = try XCTUnwrap(StubProtocol.lastBody(containing: "/purchases"))
            XCTAssertTrue(
                body.contains("\"signedTransactionInfo\""),
                "JWS proof missing from the purchase body")
            XCTAssertTrue(body.contains("\"source\":\"apple\""))
            XCTAssertTrue(body.contains("\"productId\":\"pro.monthly\""))

            let settled = try await client.waitForEntitlements(seq: registered.seq)
            XCTAssertEqual(settled.cursor, 9)
            let entitled = await client.isEntitled("pro")
            XCTAssertTrue(entitled)
        }

        /// Apple's identifiers map onto the wire contract as documented:
        /// token = originalTransactionID, transactionId = transaction id.
        func testTransactionIdentifiersMapToTheWireContract() async throws {
            StubProtocol.respond(
                containing: "/purchases", status: 201,
                body: """
                    {"eventId":"evt_2","seq":4,"duplicate":false,"customerId":"cust_1","transferred":false}
                    """)
            let client = makeClient()
            let product = try await self.product("pro.lifetime")
            _ = try await RevnixStoreKit.purchase(product, client: client)

            let body = try XCTUnwrap(StubProtocol.lastBody(containing: "/purchases"))
            let payload = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(body.utf8))
                    as? [String: Any])
            let all = try await allTransactions()
            let transaction = try XCTUnwrap(all.first)
            XCTAssertEqual(
                payload["token"] as? String, String(transaction.originalID))
            XCTAssertEqual(
                payload["transactionId"] as? String, String(transaction.id))
        }

        /// A retryable network failure during the store callback must leave the
        /// purchase durably queued — the customer paid, so the claim cannot be
        /// lost just because the device was offline at that instant.
        func testFailedRegistrationLeavesThePurchaseQueued() async throws {
            StubProtocol.failWithConnectionError(containing: "/purchases")
            let storage = MemoryStorage()
            let client = makeClient(storage: storage)
            let product = try await self.product("pro.lifetime")

            _ = try await RevnixStoreKit.purchase(product, client: client)
            let queued = await client.pendingPurchaseCount()
            XCTAssertEqual(queued, 1, "a paid purchase was dropped")

            // Connectivity returns → the drain delivers it.
            StubProtocol.respond(
                containing: "/purchases", status: 201,
                body: """
                    {"eventId":"evt_3","seq":5,"duplicate":false,"customerId":"cust_1","transferred":false}
                    """)
            let delivered = await client.retryPendingPurchases()
            XCTAssertEqual(delivered, 1)
        }

        /// `restore()` re-registers everything the device owns; the server
        /// dedupes on the shared purchaseKey, so it is always safe to call.
        func testRestoreRegistersCurrentEntitlements() async throws {
            StubProtocol.respond(
                containing: "/purchases", status: 201,
                body: """
                    {"eventId":"evt_4","seq":6,"duplicate":true,"customerId":"cust_1","transferred":false,"restored":true}
                    """)
            let client = makeClient()
            _ = try await RevnixStoreKit.purchase(
                try await self.product("pro.lifetime"), client: client)

            let restored = await RevnixStoreKit.restore(client: client)
            XCTAssertGreaterThan(restored, 0)
        }

        private func allTransactions() async throws -> [Transaction] {
            var out: [Transaction] = []
            for await result in Transaction.all {
                if case .verified(let t) = result { out.append(t) }
            }
            return out
        }
    }
#endif
