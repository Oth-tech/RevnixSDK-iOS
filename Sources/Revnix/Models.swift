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

/// REV-263: the six paywall interactions `logPaywallEvent` can report — what
/// the customer did on a display, between the view that opened it and the
/// close or purchase that ended it. The server turns each into the ledger
/// type `paywall.<rawValue>`.
public enum RevnixPaywallEvent: String, Codable, Sendable, CaseIterable {
    /// A package was picked.
    case selected
    /// Checkout was started.
    case purchaseStarted = "purchase_started"
    /// The customer backed out at the store sheet
    /// (`Product.PurchaseResult.userCancelled`).
    case purchaseAbandoned = "purchase_abandoned"
    /// The store refused the payment.
    case purchaseFailed = "purchase_failed"
    /// Restore purchases was tapped.
    case restore
    /// The paywall itself failed — config, products, or render.
    case error
}

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
    /// A designed paywall: the block tree the dashboard's builder authored.
    /// When present `RevnixPaywallView` renders THIS and the fields above act
    /// as the fallback for apps on an SDK that predates block rendering — so
    /// an older app keeps showing a sane classic screen instead of nothing.
    public let blocks: PaywallBlockDoc?

    /// Decoded by hand for one reason: `blocks` must never be able to fail the
    /// whole config.
    ///
    /// The tree is authored by a dashboard that may be NEWER than this SDK,
    /// and it arrives over the network. If a future field made the document
    /// undecodable here, a synthesized initializer would throw and the app
    /// would lose the paywall entirely — no design AND no classic fallback,
    /// which is a screen the customer cannot buy from. `try?` degrades that to
    /// "render the classic layout", which is always a working paywall.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = try c.decode(String.self, forKey: .template)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        headline = try c.decode(String.self, forKey: .headline)
        subheadline = try c.decodeIfPresent(String.self, forKey: .subheadline)
        features = try c.decodeIfPresent([PaywallFeature].self, forKey: .features) ?? []
        ctaLabel = try c.decode(String.self, forKey: .ctaLabel)
        highlightPackageId = try c.decodeIfPresent(String.self, forKey: .highlightPackageId)
        badgeText = try c.decodeIfPresent(String.self, forKey: .badgeText)
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        heroImageUrl = try c.decodeIfPresent(String.self, forKey: .heroImageUrl)
        review = try c.decodeIfPresent(PaywallReview.self, forKey: .review)
        offer = try c.decodeIfPresent(PaywallOffer.self, forKey: .offer)
        footer = try c.decodeIfPresent(PaywallFooter.self, forKey: .footer)
        blocks = try? c.decodeIfPresent(PaywallBlockDoc.self, forKey: .blocks)
    }

    public init(
        template: String,
        mode: String? = nil,
        headline: String,
        subheadline: String? = nil,
        features: [PaywallFeature] = [],
        ctaLabel: String,
        highlightPackageId: String? = nil,
        badgeText: String? = nil,
        accent: String? = nil,
        heroImageUrl: String? = nil,
        review: PaywallReview? = nil,
        offer: PaywallOffer? = nil,
        footer: PaywallFooter? = nil,
        blocks: PaywallBlockDoc? = nil
    ) {
        self.template = template
        self.mode = mode
        self.headline = headline
        self.subheadline = subheadline
        self.features = features
        self.ctaLabel = ctaLabel
        self.highlightPackageId = highlightPackageId
        self.badgeText = badgeText
        self.accent = accent
        self.heroImageUrl = heroImageUrl
        self.review = review
        self.offer = offer
        self.footer = footer
        self.blocks = blocks
    }
}

public struct PlacementPaywall: Codable, Sendable, Equatable {
    public let paywallId: String
    public let name: String
    public let config: PaywallConfig
}

/// REV-219: the running experiment's sticky assignment for this customer.
/// Attribution only — the served `offering`/`paywall` are already the
/// variant's, so the app just renders what it gets.
public struct PlacementExperiment: Codable, Sendable, Equatable {
    public let key: String
    public let variantId: String
}

public struct PlacementResolution: Codable, Sendable, Equatable {
    public let status: String
    public let placementKey: String
    /// Published catalog revision this resolution came from.
    public let revision: Int
    public let offering: PlacementOffering
    /// Remote paywall render contract — app-rendered from `config`.
    public let paywall: PlacementPaywall?
    /// nil when no experiment applies — the server sends null, and older
    /// servers omit the key entirely; both decode to nil.
    public let experiment: PlacementExperiment?
    /// The `paywall` value exactly as the server sent it, alongside the typed
    /// view above. `paywall` is decoded through `PaywallBlockDoc`, which drops
    /// what this SDK does not understand — right for a native renderer, wrong
    /// for a host that renders the document itself (the Flutter and Capacitor
    /// bridges hand it to Dart / JS). Forward THIS from such a bridge so a
    /// document from a newer dashboard arrives untouched. nil when the server
    /// sent null or omitted the key.
    public let paywallJSON: JSONValue?
    /// `experiment` as the server sent it; same purpose as `paywallJSON`.
    public let experimentJSON: JSONValue?
    /// Set only on a dashboard QR/link preview resolution
    /// (`GET /v1/paywalls/preview/{token}`), never on a real resolve.
    public let preview: Bool?

    public init(
        status: String,
        placementKey: String,
        revision: Int,
        offering: PlacementOffering,
        paywall: PlacementPaywall? = nil,
        experiment: PlacementExperiment? = nil,
        paywallJSON: JSONValue? = nil,
        experimentJSON: JSONValue? = nil,
        preview: Bool? = nil
    ) {
        self.status = status
        self.placementKey = placementKey
        self.revision = revision
        self.offering = offering
        self.paywall = paywall
        self.experiment = experiment
        self.paywallJSON = paywallJSON
        self.experimentJSON = experimentJSON
        self.preview = preview
    }

    private enum CodingKeys: String, CodingKey {
        case status, placementKey, revision, offering, paywall, experiment, preview
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        placementKey = try c.decode(String.self, forKey: .placementKey)
        revision = try c.decode(Int.self, forKey: .revision)
        offering = try c.decode(PlacementOffering.self, forKey: .offering)
        preview = try c.decodeIfPresent(Bool.self, forKey: .preview)
        // Same key read twice: once loose, once typed. `decodeIfPresent`
        // already folds a JSON null into nil, so `.null` never lands here.
        // The typed reads are `try?` for the same reason `PaywallConfig`
        // softens `blocks`: a document from a newer dashboard must never be
        // able to fail the whole resolution — the offering and the raw copy
        // still arrive, and the typed view is simply absent.
        paywallJSON = try c.decodeIfPresent(JSONValue.self, forKey: .paywall)
        paywall = (try? c.decodeIfPresent(PlacementPaywall.self, forKey: .paywall)) ?? nil
        experimentJSON = try c.decodeIfPresent(JSONValue.self, forKey: .experiment)
        experiment = (try? c.decodeIfPresent(PlacementExperiment.self, forKey: .experiment)) ?? nil
    }

    /// The raw value wins on the way out: it is what the typed value was
    /// derived from, so the offline cache keeps everything the server sent
    /// and a later decode sees the same document the live one did.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(placementKey, forKey: .placementKey)
        try c.encode(revision, forKey: .revision)
        try c.encode(offering, forKey: .offering)
        if let raw = paywallJSON {
            try c.encode(raw, forKey: .paywall)
        } else {
            try c.encodeIfPresent(paywall, forKey: .paywall)
        }
        if let raw = experimentJSON {
            try c.encode(raw, forKey: .experiment)
        } else {
            try c.encodeIfPresent(experiment, forKey: .experiment)
        }
        try c.encodeIfPresent(preview, forKey: .preview)
    }
}
