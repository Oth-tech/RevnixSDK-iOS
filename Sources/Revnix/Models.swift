import Foundation

/// Loose JSON container for metadata / paywall config / raw payloads —
/// fields the openapi.yaml deliberately leaves open-shaped.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public enum RevnixStore: String, Codable, Sendable {
    case apple
    case google
}

// ——— GET /v1/customers/{id}/entitlements ———

public struct EntitlementSource: Codable, Sendable, Equatable {
    public let kind: String
    public let key: String
    public let isActive: Bool
    public let expiresAt: Int?
}

public struct Entitlement: Codable, Sendable, Equatable {
    public let entitlementId: String
    public let isActive: Bool
    public let expiresAt: Int?
    public let sources: [EntitlementSource]

    func inactive() -> Entitlement {
        Entitlement(
            entitlementId: entitlementId, isActive: false,
            expiresAt: expiresAt,
            sources: sources.map {
                EntitlementSource(
                    kind: $0.kind, key: $0.key, isActive: false,
                    expiresAt: $0.expiresAt)
            })
    }
}

public struct CustomerEntitlements: Codable, Sendable, Equatable {
    public let customerId: String
    /// Ledger position this read reflects (read-your-writes, ADR 0004).
    public let cursor: Int
    public let entitlements: [Entitlement]
    /// Client-populated: true when served from the offline cache.
    public var stale: Bool?
    /// Client-populated: unix ms this snapshot was fetched.
    public var fetchedAt: Int?
}

// ——— POST /v1/purchases ———

public struct RegisterPurchaseInput: Sendable {
    public let source: RevnixStore
    /// Apple: originalTransactionId · Google: purchaseToken.
    public let token: String
    public let productId: String
    public let transactionId: String
    public let occurredAt: Int?
    public let expiresAt: Int?
    /// StoreKit 2 JWS — the proof path; claims without it are provisional.
    public let signedTransactionInfo: String?
    public let rawPayload: JSONValue?

    public init(
        source: RevnixStore, token: String, productId: String,
        transactionId: String, occurredAt: Int? = nil, expiresAt: Int? = nil,
        signedTransactionInfo: String? = nil, rawPayload: JSONValue? = nil
    ) {
        self.source = source
        self.token = token
        self.productId = productId
        self.transactionId = transactionId
        self.occurredAt = occurredAt
        self.expiresAt = expiresAt
        self.signedTransactionInfo = signedTransactionInfo
        self.rawPayload = rawPayload
    }
}

public struct RegisterPurchaseResult: Codable, Sendable, Equatable {
    public let eventId: String
    /// Ledger position — poll entitlements until `cursor >= seq`.
    public let seq: Int
    public let duplicate: Bool
    /// The id THIS caller should use going forward (its canonical id).
    public let customerId: String
    public let ownedByOtherCustomer: Bool?
    public let transferred: Bool
    public let refused: String?
    public let restored: Bool?
    /// Recorded without store proof — entitlement live but time-boxed until
    /// the store confirms. Send signedTransactionInfo to avoid it.
    public let provisional: Bool?
}

// ——— GET /v1/placements/{key}/offering ———

public struct PlacementPackage: Codable, Sendable, Equatable {
    public let packageId: String
    public let productId: String
    public let metadata: JSONValue?
    public let product: JSONValue?
}

public struct PlacementOffering: Codable, Sendable, Equatable {
    public let offeringId: String
    public let displayName: String
    public let metadata: JSONValue?
    public let packages: [PlacementPackage]
}

// REV-028: remote paywall design attached to a placement. Render contract —
// the app draws this with its own components; prices still come from the
// store (StoreKit) so the display never disagrees with the charge.

/// One row in the paywall's feature list.
public struct PaywallFeature: Codable, Sendable, Equatable {
    public let icon: String?
    public let title: String
    public let description: String?
}

/// Social proof, dashboard-configured. Any layout renders the pieces that
/// are set: stars/quote card above the packages, `count` under the CTA.
public struct PaywallReview: Codable, Sendable, Equatable {
    /// 0–5; rendered as a star row.
    public let rating: Double?
    public let quote: String?
    public let author: String?
    /// e.g. "Join 2M+ users" — small line under the CTA.
    public let count: String?
}

/// Win-back/offer presentation: anchor price struck through on the
/// highlighted package, urgency line above the CTA. Any layout.
public struct PaywallOffer: Codable, Sendable, Equatable {
    public let strikethroughPrice: String?
    public let urgencyText: String?
}

/// Footer links, dashboard-configured. When a URL is set the SDK opens it
/// directly; otherwise the host app's terms/privacy handler runs.
public struct PaywallFooter: Codable, Sendable, Equatable {
    public let showRestore: Bool
    public let showTerms: Bool
    public let showPrivacy: Bool
    public let termsUrl: String?
    public let privacyUrl: String?
}

public struct PaywallConfig: Codable, Sendable, Equatable {
    /// Layout — the screen structure the paywall renders. Known values:
    /// "focus", "feature-list", "minimal", "hero", "timeline", "plans",
    /// "feature-grid", "offer", "reveal". Kept as a String so configs
    /// published with future layouts never fail decoding.
    public let template: String
    /// "dark" or "light". Absent (legacy config) = dark.
    public let mode: String?
    public let headline: String
    public let subheadline: String?
    public let features: [PaywallFeature]
    public let ctaLabel: String
    /// packageId of the visually highlighted package.
    public let highlightPackageId: String?
    /// Badge on the highlighted package, e.g. "SAVE 17%".
    public let badgeText: String?
    /// Accent hex like "#6478ff"; fall back to the app theme when absent.
    public let accent: String?
    /// Hero image URL rendered above the headline in place of the icon tile.
    public let heroImageUrl: String?
    public let review: PaywallReview?
    public let offer: PaywallOffer?
    /// Absent (legacy config) = show all three footer links.
    public let footer: PaywallFooter?
}

public struct PlacementPaywall: Codable, Sendable, Equatable {
    public let paywallId: String
    public let name: String
    public let config: PaywallConfig
}

public struct PlacementResolution: Codable, Sendable, Equatable {
    public let status: String
    public let placementKey: String
    /// Published catalog revision this resolution came from.
    public let revision: Int
    public let offering: PlacementOffering
    /// Remote paywall render contract — app-rendered from `config`.
    public let paywall: PlacementPaywall?
}
