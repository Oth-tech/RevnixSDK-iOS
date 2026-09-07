// RevnixPaywallView — renders a published PaywallConfig exactly as the
// dashboard paywall-builder previews it (PaywallPhonePreview.tsx in
// revnix-app is the reference renderer; revnix-sdk's RevnixPaywall.tsx is
// the same contract ported to React Native — keep all three in lockstep).
// The config decides template, copy, accent, badge, highlight, and hero
// image; the app supplies package titles/prices (from StoreKit) and the
// purchase handlers, so the display never disagrees with the charge.
//
// `template` is a LAYOUT id. "focus" | "feature-list" | "minimal" are the
// original three; the newer layouts (hero, timeline, plans, feature-grid,
// offer, reveal) are distinct screen structures the dashboard's template
// gallery presets over. An unrecognized template (config published by a
// newer dashboard) falls back to the classic structure instead of rendering
// nothing.
//
// Point values are the RN renderer's stylesheet values verbatim (they are
// the native-device reference proportions). RN `lineHeight` has no direct
// SwiftUI equivalent — it maps to `lineSpacing` on top of the system's
// ~1.2× default line box. Like the RN renderer, empty strings in the config
// are treated the same as absent fields.

#if canImport(SwiftUI)
import SwiftUI

// MARK: - Public surface

/// One purchasable row. `priceLabel` must come from the store (localized).
public struct RevnixPaywallPackage: Identifiable, Sendable, Equatable {
    public let packageId: String
    public let title: String
    public let priceLabel: String
    /// Renewal cycle from the product ("annual", "monthly", "weekly", …).
    /// Drives the `{period}` / `{period_short}` tags on a designed paywall;
    /// absent for lifetime and one-time products.
    public let period: String?
    /// The store's price in MINOR units, with its currency — what
    /// `{price_per_month}` and `{save_percent}` are computed from. Omit them
    /// and those tags stay visible rather than resolving to a wrong number;
    /// see `revnixMinorUnits(for:)` before converting from major units.
    public let amountMinor: Int?
    public let currency: String?
    /// REV-263: the catalog product behind this package. Only telemetry reads
    /// it — a `.selected` or `.purchaseStarted` report names the plan the way
    /// the rest of the ledger does. Optional: without it the interaction is
    /// still reported, just with no plan attached.
    public let productId: String?

    public var id: String { packageId }

    public init(
        packageId: String,
        title: String,
        priceLabel: String,
        period: String? = nil,
        amountMinor: Int? = nil,
        currency: String? = nil,
        productId: String? = nil
    ) {
        self.packageId = packageId
        self.title = title
        self.priceLabel = priceLabel
        self.period = period
        self.amountMinor = amountMinor
        self.currency = currency
        self.productId = productId
    }
}

/// Colors the paywall renders with. Defaults mirror the dashboard preview
/// chrome (a fixed dark screen) — override to match the host app's theme.
public struct RevnixPaywallTheme: Equatable {
    public var background: Color
    public var textPrimary: Color
    public var textSecondary: Color
    public var textFaint: Color
    public var border: Color
    /// Text color on accent-filled surfaces (CTA, badge).
    public var accentInk: Color

    public init(
        background: Color, textPrimary: Color, textSecondary: Color,
        textFaint: Color, border: Color, accentInk: Color
    ) {
        self.background = background
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textFaint = textFaint
        self.border = border
        self.accentInk = accentInk
    }

    /// Base theme for dark configs (and legacy configs without `mode`).
    public static let dark = RevnixPaywallTheme(
        background: rgb(0x0f1116), textPrimary: rgb(0xffffff),
        textSecondary: rgb(0x9aa0a8), textFaint: rgb(0x6b7078),
        border: rgb(0x2a2e36), accentInk: rgb(0x0a0b0d))

    /// Base theme when the dashboard config sets `mode: "light"`. Keep in
    /// lockstep with the builder preview (PaywallPhonePreview SCREEN_PALETTES).
    public static let light = RevnixPaywallTheme(
        background: rgb(0xffffff), textPrimary: rgb(0x16181d),
        textSecondary: rgb(0x5b6068), textFaint: rgb(0x9aa0a8),
        border: rgb(0xe2e5ea), accentInk: rgb(0xffffff))

    /// Partial override (the RN renderer's `Partial<RevnixPaywallTheme>`):
    /// nil fields keep the config-selected base palette.
    public struct Override: Equatable {
        public var background: Color?
        public var textPrimary: Color?
        public var textSecondary: Color?
        public var textFaint: Color?
        public var border: Color?
        public var accentInk: Color?

        public init(
            background: Color? = nil, textPrimary: Color? = nil,
            textSecondary: Color? = nil, textFaint: Color? = nil,
            border: Color? = nil, accentInk: Color? = nil
        ) {
            self.background = background
            self.textPrimary = textPrimary
            self.textSecondary = textSecondary
            self.textFaint = textFaint
            self.border = border
            self.accentInk = accentInk
        }
    }

    func applying(_ override: Override?) -> RevnixPaywallTheme {
        guard let o = override else { return self }
        var t = self
        if let v = o.background { t.background = v }
        if let v = o.textPrimary { t.textPrimary = v }
        if let v = o.textSecondary { t.textSecondary = v }
        if let v = o.textFaint { t.textFaint = v }
        if let v = o.border { t.border = v }
        if let v = o.accentInk { t.accentInk = v }
        return t
    }
}

/// What the view needs for the paywall.viewed report (REV-094) — the
/// analytics funnel's "Paywall displayed" stage. A protocol rather than
/// `RevnixClient` keeps this entrypoint decoupled from the client type,
/// the way the RN renderer's structurally-typed `client` prop does.
public protocol RevnixPaywallViewReporting: Sendable {
    func logPaywallShown(placementKey: String?, paywallId: String?) async

    /// The same report, returning the view id it generated (REV-252), so a
    /// dismissal can be tied to the display it ended.
    ///
    /// Defaulted rather than added as a bare requirement: a reporter written
    /// against the pre-REV-252 protocol keeps compiling, and its paywalls
    /// still close — the close simply carries no view id, so it is recorded
    /// without being paired.
    func logPaywallDisplay(placementKey: String?, paywallId: String?) async -> String?

    /// Reports that the customer dismissed the display `viewId` identifies.
    /// Defaulted to a no-op for the same source-compatibility reason.
    func logPaywallClosed(viewId: String, placementKey: String?, paywallId: String?) async

    /// REV-263: reports one of the six paywall interactions against the
    /// display `viewId` identifies. Defaulted to a no-op so a reporter
    /// written before the vocabulary existed keeps compiling — it simply
    /// reports views and closes, as it did before.
    func logPaywallEvent(
        _ event: RevnixPaywallEvent,
        viewId: String,
        placementKey: String?,
        paywallId: String?,
        productId: String?,
        code: String?,
        message: String?,
        eventId: String?
    ) async

    /// Reports a paint string the block renderer could not read.
    ///
    /// Local only — it never leaves the device. The renderer keeps drawing (an
    /// unreadable fill falls back to a colour from the design), so this is the
    /// only way a host learns that a paywall is rendering approximately.
    /// Defaulted so a reporter written before this method keeps compiling.
    func reportRenderDiagnostic(_ message: String)
}

public extension RevnixPaywallViewReporting {
    func reportRenderDiagnostic(_ message: String) {}

    func logPaywallDisplay(placementKey: String?, paywallId: String?) async -> String? {
        await logPaywallShown(placementKey: placementKey, paywallId: paywallId)
        return nil
    }

    func logPaywallClosed(viewId: String, placementKey: String?, paywallId: String?) async {}

    func logPaywallEvent(
        _ event: RevnixPaywallEvent,
        viewId: String,
        placementKey: String?,
        paywallId: String?,
        productId: String?,
        code: String?,
        message: String?,
        eventId: String?
    ) async {}
}

extension RevnixClient: RevnixPaywallViewReporting {}

// MARK: - View

public struct RevnixPaywallView: View {
    private let config: PaywallConfig
    private let packages: [RevnixPaywallPackage]
    /// Called with the selected packageId when the CTA is pressed.
    private let onPurchase: (String) -> Void
    private let selectedPackageId: String?
    private let onSelectPackage: ((String) -> Void)?
    /// Renders a spinner in the CTA and disables purchasing.
    private let loading: Bool
    private let onRestore: (() -> Void)?
    private let onTerms: (() -> Void)?
    private let onPrivacy: (() -> Void)?
    private let onClose: (() -> Void)?
    private let themeOverride: RevnixPaywallTheme.Override?
    private let client: (any RevnixPaywallViewReporting)?
    private let placementKey: String?
    private let paywallId: String?
    private let disableViewTracking: Bool
    /// An explicit sink for render diagnostics, for a host that renders
    /// without passing `client`. When both are given both are called.
    private let onDiagnostic: (@Sendable (RevnixDiagnostic) -> Void)?
    /// REV-271: which language a designed paywall draws its copy in.
    private let locale: String?

    @State private var internalSelected: String?
    @State private var didReportView = false
    /// The in-flight view beacon (REV-252). The close AWAITS this rather than
    /// reading an id off a field: the id only exists once the beacon's request
    /// returns, and a customer who dismisses in that window — a slow link, a
    /// paywall they never meant to open — would otherwise report a close with
    /// no id and lose the pairing.
    @State private var viewReport: Task<String?, Never>?
    /// REV-263: rises per CTA press, so a retry is its own occurrence.
    @State private var purchaseAttempts = 0
    @State private var didReportNoProducts = false
    @Environment(\.openURL) private var openURL

    /// - Parameters:
    ///   - selectedPackageId: Controlled selection; omit to let the paywall
    ///     manage it (initial selection is the config's highlight package,
    ///     else the first package).
    ///   - onClose: Dismissal (REV-252). The HOST performs it — only the app
    ///     knows whether that means dismissing a sheet, popping a screen, or
    ///     advancing onboarding — so the view never dismisses itself. Omit it
    ///     and no close is drawn at all: a dead close button is worse than
    ///     none. Passing `client` as well reports `paywall.closed` against
    ///     this display's own view id.
    ///   - client: When given, the paywall reports one paywall.viewed per
    ///     appearance (REV-094); `placementKey`/`paywallId` are the
    ///     attribution attached to the report, and `disableViewTracking`
    ///     opts out while still passing `client`.
    ///   - locale: REV-271. Which language to draw a designed paywall's copy
    ///     in. Omit and the device's own is used, which is what makes the
    ///     paywall match the rest of the app; pass one when the app has its
    ///     own in-app language switch, so the paywall follows the app rather
    ///     than the OS. A paywall with no translations ignores it, and any
    ///     string the chosen language does not translate falls back to the
    ///     authored copy rather than rendering blank.
    public init(
        config: PaywallConfig,
        packages: [RevnixPaywallPackage],
        onPurchase: @escaping (String) -> Void,
        selectedPackageId: String? = nil,
        onSelectPackage: ((String) -> Void)? = nil,
        loading: Bool = false,
        onRestore: (() -> Void)? = nil,
        onTerms: (() -> Void)? = nil,
        onPrivacy: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        theme: RevnixPaywallTheme.Override? = nil,
        client: (any RevnixPaywallViewReporting)? = nil,
        placementKey: String? = nil,
        paywallId: String? = nil,
        disableViewTracking: Bool = false,
        onDiagnostic: (@Sendable (RevnixDiagnostic) -> Void)? = nil,
        locale: String? = nil
    ) {
        self.config = config
        self.packages = packages
        self.onPurchase = onPurchase
        self.selectedPackageId = selectedPackageId
        self.onSelectPackage = onSelectPackage
        self.loading = loading
        self.onRestore = onRestore
        self.onTerms = onTerms
        self.onPrivacy = onPrivacy
        self.onClose = onClose
        self.themeOverride = theme
        self.locale = locale
        self.client = client
        self.placementKey = placementKey
        self.paywallId = paywallId
        self.disableViewTracking = disableViewTracking
        self.onDiagnostic = onDiagnostic
    }

    // MARK: Resolved config

    // Currency symbols the anchor-price guard recognizes (majors; a
    // symbol-less anchor can't be judged and renders as entered).
    private static let currencySymbols: Set<Character> = [
        "$", "€", "£", "¥", "₹", "₩", "₽", "₺", "₫", "₪", "฿", "₴", "₦", "₱",
    ]

    private static let defaultAccent = rgb(0x6478ff)

    // Base scheme comes from the dashboard config (mode: dark|light, absent
    // = dark for legacy configs); the host app's explicit theme wins on top.
    private var theme: RevnixPaywallTheme {
        (config.mode == "light" ? RevnixPaywallTheme.light : .dark)
            .applying(themeOverride)
    }

    private var accent: Color {
        present(config.accent).flatMap(Color.init(revnixHex:)) ?? Self.defaultAccent
    }

    /// `${accent}26` in the RN renderer — 15% alpha tile/chip fill.
    private var accentSoft: Color { accent.opacity(Double(0x26) / 255) }
    /// `${accent}40` — 25% alpha rail/dot tint.
    private var accentTint: Color { accent.opacity(Double(0x40) / 255) }

    // Soft card surface used by the feature-grid / reveal / review blocks.
    // Not part of the public theme — derived from the config's mode, in
    // lockstep with the dashboard preview's SCREEN_PALETTES.card.
    private var cardBg: Color {
        config.mode == "light" ? rgb(0xf4f5f7) : rgb(0x181b22)
    }

    private var heroURL: URL? {
        present(config.heroImageUrl).flatMap(URL.init(string:))
    }

    // Same template semantics as the dashboard preview: "minimal" shows only
    // the highlighted package; feature bullets render on the feature layouts.
    private var shown: [RevnixPaywallPackage] {
        if config.template == "minimal",
            let highlight = present(config.highlightPackageId)
        {
            return packages.filter { $0.packageId == highlight }
        }
        return packages
    }

    private var selectedId: String? {
        if let controlled = selectedPackageId { return controlled }
        if let internalSelected,
            shown.contains(where: { $0.packageId == internalSelected })
        {
            return internalSelected
        }
        return shown.first { $0.packageId == config.highlightPackageId }?
            .packageId ?? shown.first?.packageId
    }

    /// A designed paywall renders every package — the design's own layout
    /// decides what to show, and `template` plays no part in it — so its
    /// selection resolves against `packages` rather than the template-filtered
    /// `shown`. Resolving against `shown` would silently drop a tap on any
    /// card the classic "minimal" filter happens to exclude.
    ///
    /// The rule itself (host → own tap → highlight → first, each only if it
    /// names an offered package) is `revnixSelectedPackageId`, shared with the
    /// tests that walk the cross-SDK fixture.
    private var blockSelectedId: String? {
        revnixSelectedPackageId(
            host: selectedPackageId, internal: internalSelected,
            highlight: config.highlightPackageId, packages: packages
        )
    }

    private func select(_ packageId: String) {
        internalSelected = packageId
        reportSelect(packageId)
        onSelectPackage?(packageId)
    }

    /// Every CTA path goes through here, so the start report can never be
    /// wired on one render path and forgotten on the other.
    private func purchase(_ packageId: String) {
        reportPurchaseStart(packageId)
        onPurchase(packageId)
    }

    /// Restore, likewise — the report rides along with the host's handler.
    private var restoreAction: (() -> Void)? {
        guard let onRestore else { return nil }
        return {
            reportInteraction(.restore)
            onRestore()
        }
    }

    // The anchor is dashboard free text while priceLabel is the store's
    // localized price — never pair them when their currency symbols disagree,
    // or a EUR customer would see a struck-through USD anchor next to the
    // real charge (this file's "display never disagrees with the charge"
    // rule; kept in lockstep with the preview's anchorPriceFor). Symbol-less
    // anchors can't be judged and pass through.
    private func anchorPrice(for priceLabel: String) -> String? {
        guard let anchor = present(config.offer?.strikethroughPrice) else {
            return nil
        }
        guard let symbol = anchor.first(where: { Self.currencySymbols.contains($0) })
        else { return anchor }
        return priceLabel.contains(symbol) ? anchor : nil
    }

    // MARK: Body

    // Responsive rules (mirroring the RN renderer's scrollContent/content):
    //  · the column sits vertically centered on tall screens (no dead bottom
    //    half) and scrolls normally when it overflows;
    //  · on tablets/wide screens the column stays a readable width (max 440),
    //    horizontally centered, instead of stretching edge to edge.
    public var body: some View {
        // Precedence: a designed paywall (`config.blocks`) wins over the
        // classic layouts below, which stay the fallback for every paywall
        // published before the block builder — so anything already live
        // renders unchanged.
        if let blockDoc = config.blocks {
            // REV-271: the language overlay is applied ONCE, here, so every
            // view below reads plain strings and none of them can forget to
            // localize one. A paywall with no translations returns itself.
            blockScreen(blockDoc.localized(locale ?? revnixDeviceLocale()))
        } else {
            classicBody
        }
    }

    /// The designed-paywall path. The document carries its own palette, so the
    /// classic theme and the `template` layout play no part here.
    private func blockScreen(_ blockDoc: PaywallBlockDoc) -> some View {
        RevnixPaywallBlockView(
            doc: blockDoc,
            ctx: BlockContext(
                doc: blockDoc,
                packages: packages,
                selectedPackageId: blockSelectedId,
                loading: loading,
                heroImageUrl: config.heroImageUrl,
                footerTermsUrl: config.footer?.termsUrl,
                footerPrivacyUrl: config.footer?.privacyUrl,
                onPurchase: { id in if !loading { purchase(id) } },
                onSelect: { id in select(id) },
                onRestore: restoreAction,
                onTerms: onTerms,
                onPrivacy: onPrivacy,
                onClose: onClose.map { close in { reportCloseThen(close) } },
                openURL: { url in openURL(url) },
                onDiagnostic: renderDiagnostic
            )
        )
        .onAppear(perform: reportOnAppear)
    }

    /// The renderer's diagnostic sink, or nil when the host wired neither a
    /// client nor a callback — in which case building a message per unreadable
    /// value would be pure waste, and the nil is what suppresses it.
    private var renderDiagnostic: ((String) -> Void)? {
        guard client != nil || onDiagnostic != nil else { return nil }
        let client = client
        let explicit = onDiagnostic
        return { message in
            client?.reportRenderDiagnostic(message)
            explicit?(RevnixDiagnostic(op: "paywall.render", message: message))
        }
    }

    private var classicBody: some View {
        GeometryReader { geo in
            let contentWidth = min(440, max(0, geo.size.width - 48))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    layoutBody(contentWidth: contentWidth)
                }
                .frame(width: contentWidth)
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .frame(minHeight: geo.size.height)
            }
        }
        .background(theme.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) { classicClose }
        .onAppear(perform: reportOnAppear)
    }

    /// The dismiss affordance the classic layouts get (REV-252).
    ///
    /// The nine `template` layouts have the same problem the designed ones had
    /// — nothing on the screen closes them — and `onClose` is a parameter of
    /// the shared view, so a host that wires it must get a close on either
    /// path rather than silently nothing. Classic layouts author no elements
    /// of their own, so there is never a design chip to suppress: the rule
    /// reduces to "draw it whenever the host wired a handler".
    @ViewBuilder private var classicClose: some View {
        if let onClose {
            Button { reportCloseThen(onClose) } label: {
                Text(verbatim: "\u{00D7}")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 30, height: 30)
                    .background(theme.textPrimary.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(14)
        }
    }

    /// One view per appearance of this view identity: a re-presented paywall
    /// (new sheet / new identity) is a genuine new display; re-renders and
    /// navigation round-trips are not — the RN renderer's one-report-per-mount
    /// rule. Shared by both render paths so a designed paywall reports its
    /// view exactly like a classic one.
    /// Both render paths' `onAppear`. The view report goes first so the
    /// display exists before anything is reported against it.
    private func reportOnAppear() {
        reportViewOnce()
        reportNoProductsOnce()
    }

    private func reportViewOnce() {
        guard let client, !disableViewTracking, !didReportView else { return }
        didReportView = true
        let placementKey = placementKey
        let paywallId = paywallId
        viewReport = Task {
            // A reporter that predates REV-252 answers nil; the close then
            // still fires, it just cannot be paired with this display.
            await client.logPaywallDisplay(placementKey: placementKey, paywallId: paywallId)
        }
    }

    // ——— REV-263: the interaction vocabulary ———
    //
    // The view reports what it genuinely OBSERVES: the selection change, the
    // CTA press, the restore press, and an offering that arrived with nothing
    // to sell. It never reports the purchase OUTCOME — the StoreKit call
    // happens in the host, so only the host knows whether the customer
    // cancelled at the sheet or the payment was refused. Report those with
    // `client.logPaywallEvent(.purchaseAbandoned / .purchaseFailed, ...)`
    // from your own `Product.purchase()` handling.
    private func reportInteraction(
        _ event: RevnixPaywallEvent,
        productId: String? = nil,
        code: String? = nil,
        message: String? = nil,
        eventId: String? = nil
    ) {
        guard let client, !disableViewTracking, let viewReport else { return }
        let placementKey = placementKey
        let paywallId = paywallId
        Task {
            // Awaiting the view beacon for the same reason the close does: an
            // interaction reported before the display id exists could not be
            // tied to the display it happened on.
            guard let viewId = await viewReport.value else { return }
            await client.logPaywallEvent(
                event,
                viewId: viewId,
                placementKey: placementKey,
                paywallId: paywallId,
                productId: productId,
                code: code,
                message: message,
                eventId: eventId.map { "\(viewId):\($0)" }
            )
        }
    }

    /// The catalog product behind a package, so a report names the plan the
    /// way the rest of the ledger does. Nil when the offering did not carry
    /// one — reporting the package id instead would look like a product that
    /// does not exist.
    private func productId(for packageId: String) -> String? {
        packages.first { $0.packageId == packageId }?.productId
    }

    /// Selection. One report per (display, package): a customer toggling
    /// monthly → yearly → monthly weighed two plans, not three, and the
    /// server's default key (the viewId alone) would have kept only the first.
    private func reportSelect(_ packageId: String) {
        reportInteraction(
            .selected, productId: productId(for: packageId), eventId: "sel:\(packageId)")
    }

    /// Checkout start. The attempt counter rises per press so a retry after a
    /// failure is its own occurrence rather than a duplicate of the first try.
    private func reportPurchaseStart(_ packageId: String) {
        purchaseAttempts += 1
        reportInteraction(
            .purchaseStarted,
            productId: productId(for: packageId),
            eventId: "buy:\(purchaseAttempts)")
    }

    /// An offering with nothing to sell is the one failure the view can see by
    /// itself, and the one most worth knowing about: the paywall painted, the
    /// customer could not buy. Once per display, alongside the view report.
    private func reportNoProductsOnce() {
        guard packages.isEmpty, !didReportNoProducts else { return }
        didReportNoProducts = true
        reportInteraction(
            .error, code: "no_products", message: "paywall displayed with no packages")
    }

    /// Runs the host's dismissal, reporting `paywall.closed` alongside it
    /// (REV-252). The host's closure runs FIRST and unconditionally: the
    /// beacon is best-effort, and an analytics failure must never be able to
    /// trap the customer on the screen.
    private func reportCloseThen(_ close: @escaping () -> Void) {
        close()
        guard let client, !disableViewTracking, let viewReport else { return }
        let placementKey = placementKey
        let paywallId = paywallId
        Task {
            // Awaiting the view beacon is what keeps the pair intact when the
            // customer dismisses before it lands. It has usually finished long
            // ago, in which case this resumes immediately.
            guard let viewId = await viewReport.value else { return }
            await client.logPaywallClosed(
                viewId: viewId, placementKey: placementKey, paywallId: paywallId)
        }
    }

    @ViewBuilder
    private func layoutBody(contentWidth: CGFloat) -> some View {
        switch config.template {
        case "hero":
            heroBanner
            featureChecks
            reviewCard
            packageRows(shown, withBadge: true, contentWidth: contentWidth)
            tail(contentWidth: contentWidth)
        case "timeline":
            heroOrIcon
            headlineBlock
            timelineBlock
            reviewCard
            packageRows(shown, withBadge: true, contentWidth: contentWidth)
            tail(contentWidth: contentWidth)
        case "plans":
            heroOrIcon
            headlineBlock
            // Columns stay readable up to 3 — beyond that the layout falls
            // back to stacked rows (never drop a purchasable package), same
            // rule as the dashboard preview.
            if shown.count <= 3 {
                planColumns
            } else {
                packageRows(shown, withBadge: true, contentWidth: contentWidth)
            }
            featureChecks
            reviewCard
            tail(contentWidth: contentWidth)
        case "feature-grid":
            heroOrIcon
            headlineBlock
            featureGrid
            reviewCard
            packageRows(shown, withBadge: true, contentWidth: contentWidth)
            tail(contentWidth: contentWidth)
        case "offer":
            heroOrIcon
            offerPill(contentWidth: contentWidth)
            headlineBlock
            offerSpotlight(contentWidth: contentWidth)
            reviewCard
            tail(contentWidth: contentWidth)
        case "reveal":
            progressDots
            heroOrIcon
            headlineBlock
            revealCards
            packageRows(shown, withBadge: true, contentWidth: contentWidth)
            tail(contentWidth: contentWidth)
        default:
            // focus | feature-list | minimal — the original structure,
            // unchanged for legacy configs (review/offer blocks only exist
            // when configured).
            heroOrIcon
            headlineBlock
            if config.template == "feature-list" { featureBullets }
            reviewCard
            packageRows(shown, withBadge: true, contentWidth: contentWidth)
            tail(contentWidth: contentWidth)
        }
    }

    /// Tail shared by every layout: urgency → CTA → count → footer.
    @ViewBuilder
    private func tail(contentWidth: CGFloat) -> some View {
        urgencyLine
        cta
        countLine
        footerBlock
    }

    // MARK: Shared blocks (each layout composes a subset; keep every block
    // in lockstep with the same-named block in RevnixPaywall.tsx /
    // PaywallPhonePreview.tsx)

    /// Classic header: hero image card (or accent icon tile) + the centered
    /// headline/subheadline below it.
    @ViewBuilder
    private var heroOrIcon: some View {
        if present(config.heroImageUrl) != nil {
            coverImage(heroURL)
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.top, 8)
                .padding(.bottom, 22)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(accentSoft)
                    .frame(width: 64, height: 64)
                Text("◆")
                    .font(.system(size: 27))
                    .foregroundStyle(accent)
            }
            .padding(.top, 8)
            .padding(.bottom, 22)
        }
    }

    @ViewBuilder
    private var headlineBlock: some View {
        Text(config.headline)
            .rnType(26, .heavy)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .foregroundStyle(theme.textPrimary)
            .padding(.bottom, 10)
        if let sub = present(config.subheadline) {
            Text(sub)
                .rnType(15, lineHeight: 21)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .foregroundStyle(theme.textSecondary)
                .padding(.bottom, 26)
        }
    }

    /// Hero layout banner: full-width media with a content-safe scrim
    /// overlay carrying the headline/subheadline (always light-on-scrim).
    /// Falls back to an accent field with the brand glyph when no hero
    /// image is set.
    private var heroBanner: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                Text(config.headline)
                    .rnType(24, .heavy)
                    .foregroundStyle(Color.white)
                if let sub = present(config.subheadline) {
                    Text(sub)
                        .rnType(13.5, lineHeight: 19)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(Color.black.opacity(0.45))
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background {
            if present(config.heroImageUrl) != nil {
                coverImage(heroURL)
            } else {
                ZStack {
                    accent
                    Text("◆")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .padding(.bottom, 72)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.top, 8)
        .padding(.bottom, 22)
    }

    /// Legacy feature bullets (feature-list layout).
    @ViewBuilder
    private var featureBullets: some View {
        if !config.features.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(config.features.enumerated()), id: \.offset) { _, f in
                    HStack(alignment: .top, spacing: 12) {
                        Text(present(f.icon) ?? "✓")
                            .rnType(15, lineHeight: 21)
                            .foregroundStyle(accent)
                            .frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(f.title)
                                .rnType(15.5, .semibold, lineHeight: 21)
                                .foregroundStyle(theme.textPrimary)
                            if let desc = present(f.description) {
                                Text(desc)
                                    .rnType(13, lineHeight: 18)
                                    .foregroundStyle(theme.textSecondary)
                                    .padding(.top, 1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, 26)
        }
    }

    /// Compact single-line checks (hero banner body, plans checklist).
    @ViewBuilder
    private var featureChecks: some View {
        if !config.features.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(config.features.enumerated()), id: \.offset) { _, f in
                    HStack(alignment: .center, spacing: 10) {
                        Text(present(f.icon) ?? "✓")
                            .rnType(14)
                            .foregroundStyle(accent)
                            .frame(width: 20, alignment: .leading)
                        Text(f.title)
                            .rnType(14.5, .medium, lineHeight: 20)
                            .foregroundStyle(theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    /// Trial timeline: icon dots joined by an accent rail; the first step is
    /// filled solid ("you are here"), later steps are tinted.
    @ViewBuilder
    private var timelineBlock: some View {
        if !config.features.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(config.features.enumerated()), id: \.offset) { i, f in
                    let last = i == config.features.count - 1
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(i == 0 ? accent : accentSoft)
                                .frame(width: 34, height: 34)
                            Text(present(f.icon) ?? "✓")
                                .rnType(14)
                                .foregroundStyle(i == 0 ? theme.accentInk : accent)
                        }
                        .frame(width: 34)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(f.title)
                                .rnType(15.5, .semibold, lineHeight: 21)
                                .foregroundStyle(theme.textPrimary)
                            if let desc = present(f.description) {
                                Text(desc)
                                    .rnType(13, lineHeight: 18)
                                    .foregroundStyle(theme.textSecondary)
                                    .padding(.top, 1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                        .padding(.bottom, last ? 0 : 22)
                    }
                    .background(alignment: .leading) {
                        if !last {
                            // The rail segment toward the next dot: starts
                            // below this row's 34pt dot, 4pt inset each end.
                            Rectangle()
                                .fill(accentTint)
                                .frame(width: 2)
                                .padding(.top, 34 + 4)
                                .padding(.bottom, 4)
                                .frame(width: 34)
                        }
                    }
                }
            }
            .padding(.bottom, 26)
        }
    }

    /// Feature grid: two-column soft cards with an accent icon tile each.
    /// Paired rows mirror the RN flex-wrap: cards in a row share its height,
    /// and an odd last card grows to the full row (RN's flexGrow).
    @ViewBuilder
    private var featureGrid: some View {
        if !config.features.isEmpty {
            let pairs = stride(from: 0, to: config.features.count, by: 2).map {
                Array(config.features[$0..<min($0 + 2, config.features.count)])
            }
            VStack(spacing: 10) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(pair.enumerated()), id: \.offset) { _, f in
                            gridCard(f)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func gridCard(_ f: PaywallFeature) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(accentSoft)
                    .frame(width: 34, height: 34)
                Text(present(f.icon) ?? "✓")
                    .rnType(15)
                    .foregroundStyle(accent)
            }
            .padding(.bottom, 9)
            Text(f.title)
                .rnType(13.5, .semibold, lineHeight: 18)
                .foregroundStyle(theme.textPrimary)
            if let desc = present(f.description) {
                Text(desc)
                    .rnType(12, lineHeight: 16)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.top, 3)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Reveal: onboarding-style progress dots + numbered benefit cards.
    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(i == 0 ? accent : accentTint)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var revealCards: some View {
        if !config.features.isEmpty {
            VStack(spacing: 10) {
                ForEach(Array(config.features.enumerated()), id: \.offset) { i, f in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(accentSoft)
                                .frame(width: 26, height: 26)
                            Text(String(i + 1))
                                .rnType(13, .bold)
                                .foregroundStyle(accent)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(f.title)
                                .rnType(15, .semibold, lineHeight: 20)
                                .foregroundStyle(theme.textPrimary)
                            if let desc = present(f.description) {
                                Text(desc)
                                    .rnType(13, lineHeight: 18)
                                    .foregroundStyle(theme.textSecondary)
                                    .padding(.top, 1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .background(cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.bottom, 24)
        }
    }

    /// Social proof card: star row (+ numeric rating), quote, attribution.
    @ViewBuilder
    private var reviewCard: some View {
        let review = config.review
        let hasCard =
            review != nil
            && (review?.rating != nil || present(review?.quote) != nil)
        if hasCard {
            VStack(spacing: 0) {
                if let rating = review?.rating {
                    HStack(spacing: 0) {
                        ForEach(1...5, id: \.self) { n in
                            Text("★")
                                .rnType(15)
                                .foregroundStyle(
                                    n <= Int(rating.rounded())
                                        ? accent : theme.border
                                )
                                .padding(.horizontal, 1)
                        }
                        Text(ratingLabel(rating))
                            .rnType(13, .semibold)
                            .foregroundStyle(theme.textPrimary)
                            .padding(.leading, 6)
                    }
                }
                if let quote = present(review?.quote) {
                    Text("“\(quote)”")
                        .rnType(13.5, lineHeight: 19)
                        .italic()
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.textPrimary)
                        .padding(.top, 8)
                }
                if let author = present(review?.author) {
                    Text("— \(author)")
                        .rnType(12)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.bottom, 22)
        }
    }

    /// e.g. "Join 2M+ users" — small line under the CTA.
    @ViewBuilder
    private var countLine: some View {
        if let count = present(config.review?.count) {
            Text(count)
                .rnType(12.5)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .foregroundStyle(theme.textSecondary)
                .padding(.bottom, 14)
        }
    }

    /// Offer urgency line above the CTA.
    @ViewBuilder
    private var urgencyLine: some View {
        if let urgency = present(config.offer?.urgencyText) {
            Text(urgency)
                .rnType(13, .semibold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .foregroundStyle(accent)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func priceLine(
        _ pkg: RevnixPaywallPackage, highlighted: Bool
    ) -> some View {
        let anchor = highlighted ? anchorPrice(for: pkg.priceLabel) : nil
        if let anchor {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(anchor)
                    .rnType(13)
                    .strikethrough()
                    .monospacedDigit()
                    .foregroundStyle(theme.textFaint)
                Text(pkg.priceLabel)
                    .rnType(14)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.top, 2)
        } else {
            Text(pkg.priceLabel)
                .rnType(14)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
                .padding(.top, 2)
        }
    }

    private func badgePill(_ text: String, maxWidth: CGFloat) -> some View {
        Text(text)
            .lineLimit(1)
            .rnType(11, .bold)
            .foregroundStyle(theme.accentInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(accent))
            // A long badge string must never grow past the card edge (kept
            // in lockstep with the dashboard preview, which truncates the
            // same way).
            .frame(maxWidth: maxWidth)
    }

    /// Standard package rows (all layouts except plans columns / offer
    /// spotlight). `withBadge: false` suppresses the row badge where the
    /// layout already presents the badge elsewhere (offer pill).
    private func packageRows(
        _ list: [RevnixPaywallPackage], withBadge: Bool, contentWidth: CGFloat
    ) -> some View {
        VStack(spacing: 12) {
            ForEach(list) { pkg in
                let selected = pkg.packageId == selectedId
                let highlighted = pkg.packageId == config.highlightPackageId
                let badge =
                    withBadge && highlighted ? present(config.badgeText) : nil
                Button {
                    select(pkg.packageId)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(pkg.title)
                            .rnType(16, .semibold)
                            .foregroundStyle(theme.textPrimary)
                        priceLine(pkg, highlighted: highlighted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                selected ? accent : theme.border,
                                lineWidth: selected ? 2 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            badgePill(badge, maxWidth: contentWidth * 0.8)
                                .offset(x: -14, y: -11)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(.bottom, 22)
    }

    /// Plans layout: packages side by side as tier columns; the highlighted
    /// tier carries the badge pill inside the column.
    private var planColumns: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(shown) { pkg in
                let selected = pkg.packageId == selectedId
                let highlighted = pkg.packageId == config.highlightPackageId
                Button {
                    select(pkg.packageId)
                } label: {
                    VStack(spacing: 0) {
                        if highlighted, let badge = present(config.badgeText) {
                            badgePill(badge, maxWidth: .infinity)
                                .padding(.bottom, 7)
                        }
                        Text(pkg.title)
                            .rnType(14, .semibold, lineHeight: 19)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(theme.textPrimary)
                        if highlighted,
                            let anchor = anchorPrice(for: pkg.priceLabel)
                        {
                            Text(anchor)
                                .rnType(13)
                                .strikethrough()
                                .monospacedDigit()
                                .foregroundStyle(theme.textFaint)
                        }
                        Text(pkg.priceLabel)
                            .rnType(15, .bold)
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 14)
                    .frame(maxHeight: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                selected ? accent : theme.border,
                                lineWidth: selected ? 2 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 22)
    }

    /// Offer layout: the badge becomes a large centered pill; the
    /// highlighted (else first) package renders as a spotlight card with
    /// the anchor price.
    private var spotlightPkg: RevnixPaywallPackage? {
        shown.first { $0.packageId == config.highlightPackageId } ?? shown.first
    }

    @ViewBuilder
    private func offerPill(contentWidth: CGFloat) -> some View {
        if let badge = present(config.badgeText) {
            Text(badge)
                .lineLimit(1)
                .rnType(12, .bold)
                .foregroundStyle(theme.accentInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(accent))
                .frame(maxWidth: contentWidth * 0.8)
                .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private func offerSpotlight(contentWidth: CGFloat) -> some View {
        if let pkg = spotlightPkg {
            let selected = pkg.packageId == selectedId
            Button {
                select(pkg.packageId)
            } label: {
                VStack(spacing: 0) {
                    Text(pkg.title)
                        .rnType(16, .semibold)
                        .foregroundStyle(theme.textPrimary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let anchor = anchorPrice(for: pkg.priceLabel) {
                            Text(anchor)
                                .rnType(15)
                                .strikethrough()
                                .monospacedDigit()
                                .foregroundStyle(theme.textFaint)
                        }
                        Text(pkg.priceLabel)
                            .rnType(24, .heavy)
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary)
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(18)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            selected ? accent : theme.border, lineWidth: 2)
                )
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .padding(.bottom, 12)
            if shown.count > 1 {
                packageRows(
                    shown.filter { $0.packageId != pkg.packageId },
                    withBadge: false, contentWidth: contentWidth)
            }
        }
    }

    private var cta: some View {
        Button {
            if !loading, let selectedId { purchase(selectedId) }
        } label: {
            ZStack {
                if loading {
                    ProgressView().tint(theme.accentInk)
                } else {
                    Text(config.ctaLabel)
                        .rnType(16.5, .bold)
                        .foregroundStyle(theme.accentInk)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(accent))
        }
        // Not `.plain`: that style dims the whole accent fill while
        // disabled, but the RN CTA keeps full accent behind the spinner.
        .buttonStyle(UndimmedButtonStyle())
        .disabled(loading || selectedId == nil)
        .padding(.bottom, 14)
    }

    // Footer links are dashboard-configured (config.footer); a legacy config
    // without the field keeps the original always-on footer. Explicit host
    // handlers win over config URLs — the app knows best how to open its own
    // legal pages (in-app browser etc.); the URL is the no-handler fallback.
    private struct FooterItem: Identifiable {
        let show: Bool
        let label: String
        let action: (() -> Void)?
        var id: String { label }
    }

    private var footerItems: [FooterItem] {
        let footer = config.footer
        let open = { (url: String?) -> (() -> Void)? in
            guard let url = present(url), let parsed = URL(string: url) else {
                return nil
            }
            return { openURL(parsed) }
        }
        return [
            FooterItem(
                show: footer?.showRestore ?? true, label: "Restore",
                action: restoreAction),
            FooterItem(
                show: footer?.showTerms ?? true, label: "Terms",
                action: onTerms ?? open(footer?.termsUrl)),
            FooterItem(
                show: footer?.showPrivacy ?? true, label: "Privacy",
                action: onPrivacy ?? open(footer?.privacyUrl)),
        ].filter { $0.show }
    }

    @ViewBuilder
    private var footerBlock: some View {
        let items = footerItems
        if !items.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 {
                        Text(" · ")
                            .rnType(13)
                            .foregroundStyle(theme.textFaint)
                            .padding(.vertical, 4)
                    }
                    Button {
                        item.action?()
                    } label: {
                        Text(item.label)
                            .rnType(13)
                            .foregroundStyle(theme.textFaint)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Remote image scaled to cover its frame (RN resizeMode="cover"); the
    /// clear base keeps the fill from blowing the layout past its frame.
    private func coverImage(_ url: URL?) -> some View {
        Color.clear.overlay {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                }
            }
        }
        .clipped()
    }
}

// MARK: - Private helpers

/// Renders the label as-is (no press/disabled dimming) — RN Pressable
/// applies no default feedback, and the loading CTA must keep its full
/// accent fill behind the spinner.
private struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// JS-truthiness mirror: the RN renderer's `config.field ?` treats an empty
/// string the same as an absent one.
private func present(_ value: String?) -> String? {
    (value?.isEmpty ?? true) ? nil : value
}

/// JS `String(Number)`: whole ratings render without a trailing ".0".
private func ratingLabel(_ rating: Double) -> String {
    rating == rating.rounded() && rating.magnitude < Double(Int.max)
        ? String(Int(rating)) : String(rating)
}

private func rgb(_ value: UInt32) -> Color {
    Color(
        red: Double((value >> 16) & 0xff) / 255,
        green: Double((value >> 8) & 0xff) / 255,
        blue: Double(value & 0xff) / 255)
}

extension Color {
    /// Parses a dashboard accent like "#6478ff" (or "#fff"); nil on
    /// anything else so the caller falls back to the default accent.
    fileprivate init?(revnixHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = rgb(v)
    }
}

extension View {
    /// RN Text style shorthand: fontSize/fontWeight, with RN `lineHeight`
    /// approximated as extra line spacing over the system's ~1.2× line box.
    fileprivate func rnType(
        _ size: CGFloat, _ weight: Font.Weight = .regular,
        lineHeight: CGFloat? = nil
    ) -> some View {
        font(.system(size: size, weight: weight))
            .lineSpacing(lineHeight.map { max(0, $0 - size * 1.2) } ?? 0)
    }
}
#endif
