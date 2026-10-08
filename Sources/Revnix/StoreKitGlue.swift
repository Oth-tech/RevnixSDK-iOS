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
                    _ = try? await register(update, client: client, finish: true)
                }
            }
        }

        /// One call from tap to unlocked gate: StoreKit purchase → register
        /// with proof → wait for the ledger to reflect it (read-your-writes).
        /// Nil when the customer cancelled or the purchase is pending. Throws
        /// the `RevnixError` from registration: a retryable one means the
        /// claim is queued and the transaction finished, a non-retryable one
        /// leaves it unfinished.
        @discardableResult
        public static func purchase(
            _ product: Product, client: RevnixClient,
            options: Set<Product.PurchaseOption> = []
        ) async throws -> RegisterPurchaseResult? {
            let outcome = try await product.purchase(options: options)
            switch outcome {
            case .success(let verification):
                return try await register(
                    verification, client: client, finish: true, throwOnFailure: true)
            case .userCancelled, .pending:
                return nil
            @unknown default:
                return nil
            }
        }

        /// Re-register everything the device is entitled to. The server
        /// dedupes on the shared purchaseKey, so this is always safe. Counts
        /// claims delivered or durably queued.
        @discardableResult
        public static func restore(client: RevnixClient) async -> Int {
            var registered = 0
            for await entitlement in Transaction.currentEntitlements {
                do {
                    _ = try await register(
                        entitlement, client: client, finish: false, throwOnFailure: true)
                    registered += 1
                } catch let err as RevnixError where err.isRetryable {
                    registered += 1
                } catch {}
            }
            return registered
        }

        @discardableResult
        private static func register(
            _ verification: VerificationResult<Transaction>,
            client: RevnixClient, finish: Bool, throwOnFailure: Bool = false
        ) async throws -> RegisterPurchaseResult? {
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
            } catch let err as RevnixError where throwOnFailure && err.isRetryable {
                if finish { await transaction.finish() }
                throw err
            } catch let err where throwOnFailure {
                throw err
            } catch {
                // Retryable failures are already queued by the client; the
                // transaction stays unfinished so StoreKit redelivers it.
                return nil
            }
        }
    }
#endif
