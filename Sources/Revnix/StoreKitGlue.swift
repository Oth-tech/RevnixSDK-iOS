#if canImport(StoreKit)
    import Foundation
    import StoreKit

    /// StoreKit 2 glue — the reason a native SDK exists. Every path sends the
    /// JWS (`jwsRepresentation`) as store proof, so claims verify server-side
    /// against Apple's chain and are never provisional.
    @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
    public enum RevnixStoreKit {

        /// Start at app launch. Forwards every transaction update (purchases
        /// on other devices, renewals, Ask to Buy approvals, revocations) to
        /// Revnix, then finishes the transaction.
        public static func startObserving(client: RevnixClient) -> Task<Void, Never> {
            Task.detached {
                for await update in Transaction.updates {
                    await register(update, client: client, finish: true)
                }
            }
        }

        /// One call from tap to unlocked gate: StoreKit purchase → register
        /// with proof → wait for the ledger to reflect it (read-your-writes).
        @discardableResult
        public static func purchase(
            _ product: Product, client: RevnixClient,
            options: Set<Product.PurchaseOption> = []
        ) async throws -> RegisterPurchaseResult? {
            let outcome = try await product.purchase(options: options)
            switch outcome {
            case .success(let verification):
                return await register(verification, client: client, finish: true)
            case .userCancelled, .pending:
                return nil
            @unknown default:
                return nil
            }
        }

        /// Re-register everything the device is entitled to. The server
        /// dedupes on the shared purchaseKey, so this is always safe.
        @discardableResult
        public static func restore(client: RevnixClient) async -> Int {
            var registered = 0
            for await entitlement in Transaction.currentEntitlements {
                if await register(entitlement, client: client, finish: false) != nil {
                    registered += 1
                }
            }
            return registered
        }

        @discardableResult
        private static func register(
            _ verification: VerificationResult<Transaction>,
            client: RevnixClient, finish: Bool
        ) async -> RegisterPurchaseResult? {
            // The SERVER is the verifier of record — forward the JWS either
            // way and let it check the chain (matches the backend's
            // StoreKit-2-only contract).
            let transaction: Transaction
            switch verification {
            case .verified(let t): transaction = t
            case .unverified(let t, _): transaction = t
            }
            let input = RegisterPurchaseInput(
                source: .apple,
                token: String(transaction.originalID),
                productId: transaction.productID,
                transactionId: String(transaction.id),
                occurredAt: Int(
                    transaction.purchaseDate.timeIntervalSince1970 * 1000),
                expiresAt: transaction.expirationDate.map {
                    Int($0.timeIntervalSince1970 * 1000)
                },
                signedTransactionInfo: verification.jwsRepresentation
            )
            do {
                let result = try await client.registerPurchase(input)
                if finish { await transaction.finish() }
                return result
            } catch {
                // Retryable failures are already queued by the client; the
                // transaction stays unfinished so StoreKit redelivers it.
                return nil
            }
        }
    }
#endif
