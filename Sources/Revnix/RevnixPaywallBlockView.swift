// RevnixPaywallBlockView — the SwiftUI interpreter for designed paywalls.
//
// A paywall built in the dashboard's block builder publishes a TREE of styled
// elements on `PaywallConfig.blocks`. `RevnixPaywallView` renders that tree
// through this view when it is present, and falls back to the classic
// `template` layouts when it is not — so every paywall published before the
// block builder keeps rendering exactly as it did.
//
// revnix-app's src/components/paywall-blocks/BlockScreen.tsx is the reference
// renderer; keep the two in lockstep. The container layouts map onto SwiftUI's
// own primitives: column → VStack, row → HStack, stack → ZStack, grid →
// LazyVGrid.
//
// Two rules matter more here than in the dashboard, because a shipped app
// cannot be patched from our side:
//
//   * An unknown block type, layout or style field is SKIPPED and the rest of
//     the screen still renders. Never crash, never blank.
//   * A tag with no data behind it stays visible (`{price}` renders as
//     `{price}`) rather than resolving to something wrong — a customer must
//     never be shown a price the store will not charge.

#if canImport(SwiftUI)
import SwiftUI

// MARK: - Tag variables

/// Renewal cycles, in months. Lifetime and one-time products have no cycle.
private let monthsPerPeriod: [String: Double] = [
    "weekly": 1 / 4.345,
    "monthly": 1,
    "two_months": 2,
    "three_months": 3,
    "six_months": 6,
    "annual": 12,
]

private let periodWord: [String: String] = [
    "weekly": "week", "monthly": "month", "two_months": "2 months",
    "three_months": "3 months", "six_months": "6 months", "annual": "year",
    "lifetime": "lifetime",
]

private let periodShort: [String: String] = [
    "weekly": "wk", "monthly": "mo", "two_months": "2mo",
    "three_months": "3mo", "six_months": "6mo", "annual": "yr",
    "lifetime": "once",
]

/// Minor units per major unit. Not every currency is a hundredth: JPY and KRW
/// have no minor unit at all, so dividing by 100 would understate a price by
/// 100×. Ask Foundation for the currency's exponent rather than assume.
public func revnixMinorUnits(for currency: String) -> Double {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    let digits = formatter.maximumFractionDigits
    return pow(10, Double(digits))
}

private func money(minor: Double, currency: String) -> String {
    let per = revnixMinorUnits(for: currency)
    let major = minor / per
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    // A whole amount reads better without ".00"; a fractional one keeps it.
    let whole = minor.truncatingRemainder(dividingBy: per) == 0
    formatter.maximumFractionDigits = whole ? 0 : formatter.maximumFractionDigits
    return formatter.string(from: NSNumber(value: major)) ?? "\(major) \(currency)"
}

private func perMonthMinor(_ pkg: RevnixPaywallPackage) -> Double? {
    guard let period = pkg.period, let months = monthsPerPeriod[period], months > 0,
          let amount = pkg.amountMinor else { return nil }
    return Double(amount) / months
}

/// Fills a copy template from one package. `all` is the rest of the offering,
/// which `{save_percent}` needs to have something to compare against.
///
/// A tag this cannot answer from real package data is left in place, VISIBLE.
/// That is deliberate: a design that says `{price}` and renders a stale sample
/// is worse than one that visibly did not resolve.
public func revnixResolveTags(
    _ text: String,
    package pkg: RevnixPaywallPackage?,
    all: [RevnixPaywallPackage] = []
) -> String {
    guard let pkg, text.contains("{") else { return text }
    var out = ""
    var rest = Substring(text)
    while let open = rest.firstIndex(of: "{") {
        out += rest[rest.startIndex ..< open]
        guard let close = rest[open...].firstIndex(of: "}") else {
            out += rest[open...]
            return out
        }
        let name = String(rest[rest.index(after: open) ..< close])
        let raw = "{\(name)}"
        out += resolveOne(name: name, raw: raw, pkg: pkg, all: all)
        rest = rest[rest.index(after: close)...]
    }
    return out + rest
}

private func resolveOne(
    name: String, raw: String, pkg: RevnixPaywallPackage, all: [RevnixPaywallPackage]
) -> String {
    switch name {
    case "title": return pkg.title
    case "price": return pkg.priceLabel
    case "period": return pkg.period.flatMap { periodWord[$0] } ?? raw
    case "period_short": return pkg.period.flatMap { periodShort[$0] } ?? raw
    case "price_per_month":
        guard let per = perMonthMinor(pkg), let currency = pkg.currency else { return raw }
        return money(minor: per.rounded(), currency: currency)
    case "save_percent":
        guard let mine = perMonthMinor(pkg), mine > 0 else { return raw }
        let dearest = all.compactMap(perMonthMinor).max() ?? 0
        guard dearest > mine else { return raw }
        return "\(Int((1 - mine / dearest) * 100 + 0.5))%"
    default:
        // Unknown tag: leave it visible rather than guess.
        return raw
    }
}

// MARK: - Palette

/// Expands palette tokens (`@accent`, `@text/12`) and parses the result.
/// Anything unparseable returns nil so the caller keeps its own default rather
/// than painting a wrong colour.
func revnixBlockColor(_ value: String?, _ doc: PaywallBlockDoc) -> Color? {
    guard var raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    var alpha = 1.0
    if raw.hasPrefix("@") {
        let body = raw.dropFirst()
        let parts = body.split(separator: "/", maxSplits: 1)
        let name = String(parts[0])
        if parts.count == 2, let pct = Double(parts[1]) { alpha = max(0, min(100, pct)) / 100 }
        switch name {
        case "accent": raw = doc.accent
        case "accentInk": raw = doc.accentInk
        // The ground's FLAT base colour, which is what the dashboard answers
        // `@bg` with: it feeds the token into `color-mix()`, which cannot take
        // a gradient, so it collapses a gradient ground to one colour first.
        // Handing the raw gradient here instead made every `@bg` tint over a
        // gradient background resolve to nil and paint nothing.
        case "bg": raw = revnixBackgroundBaseColor(doc.background)
        case "text": raw = doc.textColor
        default: return nil
        }
    }
    guard let base = Color(revnixBlockHex: raw) else { return nil }
    return alpha == 1 ? base : base.opacity(alpha)
}

extension Color {
    /// Parses "#rgb", "#rrggbb", "#rrggbbaa", "rgb()/rgba()" and `transparent`.
    /// A gradient or any other named colour returns nil — the caller falls back
    /// rather than guessing.
    init?(revnixBlockHex value: String) {
        var s = value.trimmingCharacters(in: .whitespaces)
        // `transparent` appears in the shipped designs' gradient stops.
        // Rejecting it dropped the stop, and a gradient left with one stop does
        // not parse at all, so the whole fill was lost.
        if s.caseInsensitiveCompare("transparent") == .orderedSame {
            self = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0)
            return
        }
        if s.hasPrefix("#") {
            s.removeFirst()
            if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
            guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
            let hasAlpha = s.count == 8
            let r = Double((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
            let g = Double((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
            let b = Double((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
            let a = hasAlpha ? Double(v & 0xFF) / 255 : 1
            self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
            return
        }
        let lower = s.lowercased()
        guard lower.hasPrefix("rgb"), let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")")
        else { return nil }
        let nums = s[s.index(after: open) ..< close]
            .split(whereSeparator: { ", /".contains($0) })
            .compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        self = Color(
            .sRGB, red: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255,
            opacity: nums.count > 3 ? nums[3] : 1
        )
    }
}

// MARK: - Fills

/// What a `fill` (or any other paint string) resolves to.
///
/// The dashboard hands `fill` straight to CSS `background`, which takes a
/// colour *or* a gradient *or* a stack of them. Native has no such union, so
/// the two cases are separated here and painted by `RevnixFillView`.
enum RevnixBlockFill {
    case color(Color)
    /// Gradient layers BOTTOM FIRST, and NOTHING under them.
    ///
    /// The flat colour a gradient collapses to belongs only to the case where
    /// the gradient cannot be drawn. Painting it underneath one that CAN be
    /// drawn makes the box opaque, and 83 of the library's 139 gradient fills
    /// are scrims that fade through a translucent stop — they are drawn over
    /// the screen's photo precisely so it shows through.
    case gradients([RevnixGradient])
}

/// Resolves a paint string the way the dashboard's CSS `background` does.
///
/// Order matters: a plain colour is tried first (it is the overwhelmingly
/// common case and the cheap one), then the gradient forms, and only then the
/// fallback. Returning nil means "paint nothing", which is what an absent
/// `fill` has always meant.
///
/// Nothing here fails silently any more. A `fill` the design set but this SDK
/// cannot parse collapses to the first colour literal in the string — a colour
/// FROM THE DESIGN, never black — and reports through `onDiagnostic` so the
/// host can see the form its paywall used and we did not.
func revnixBlockFill(
    _ value: String?,
    _ doc: PaywallBlockDoc,
    onDiagnostic: ((String) -> Void)? = nil
) -> RevnixBlockFill? {
    guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    if let flat = revnixBlockColor(raw, doc) { return .color(flat) }

    let layers = revnixParseCssGradients(raw, isColor: { revnixBlockColor($0, doc) != nil })
    if !layers.isEmpty { return .gradients(layers) }

    // Neither a colour nor a gradient this build knows. Take a colour out of
    // the string rather than leaving the box unpainted or, worse, black.
    onDiagnostic?("unreadable fill \(raw)")
    // A pattern paints nothing rather than a stripe colour spread over the box.
    if revnixIsRepeatingPattern(raw) { return nil }
    return revnixBlockColor(revnixBackgroundBaseColor(raw), doc).map { .color($0) }
}

/// The flat colour a parsed gradient stack stands in for: the first stop of
/// the BOTTOM layer that is not fully transparent. Matches
/// `revnixBackgroundBaseColor`, but reads the parsed stops rather than the
/// source text, so a stop written as a palette token resolves too.
func revnixGradientBaseColor(_ layers: [RevnixGradient], _ doc: PaywallBlockDoc) -> Color? {
    guard let bottom = layers.first else { return nil }
    // The alpha is read off the RESOLVED stop rather than its source text, so a
    // stop written `@accent/0` counts as transparent exactly as `#6478ff00`
    // does — the text-only test called the token opaque and answered a border
    // with an invisible colour.
    var first: Color?
    for stop in bottom.stops {
        guard let resolved = revnixBlockColor(stop.color, doc) else { continue }
        if first == nil { first = resolved }
        if !revnixIsFullyTransparentStop(stop.color, doc) { return resolved }
    }
    return first
}

/// Whether a stop resolves to nothing visible. Palette tokens carry their alpha
/// in the token (`@accent/0`), so the source text alone cannot answer this.
private func revnixIsFullyTransparentStop(_ color: String, _ doc: PaywallBlockDoc) -> Bool {
    if color.hasPrefix("@") {
        let parts = color.dropFirst().split(separator: "/", maxSplits: 1)
        if parts.count == 2, let pct = Double(parts[1]) { return pct <= 0 }
        return false
    }
    return revnixIsFullyTransparent(color)
}

/// A field that can only ever be ONE colour — a border, text, a shadow.
///
/// A gradient in such a field has no native equivalent (and no CSS one either:
/// `border-color` takes no gradient, so the dashboard drops the whole
/// declaration). Collapsing it to the colour it stands for keeps the stroke or
/// the text visible, which is closer to the design's intent than losing it.
func revnixBlockStrokeColor(
    _ value: String?,
    _ doc: PaywallBlockDoc,
    onDiagnostic: ((String) -> Void)? = nil
) -> Color? {
    guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    if let flat = revnixBlockColor(raw, doc) { return flat }
    let layers = revnixParseCssGradients(raw, isColor: { revnixBlockColor($0, doc) != nil })
    if let base = revnixGradientBaseColor(layers, doc) {
        onDiagnostic?("gradient flattened in a colour-only field: \(raw)")
        return base
    }
    onDiagnostic?("unreadable colour \(raw)")
    return revnixBlockColor(revnixBackgroundBaseColor(raw), doc)
}

/// Paints a resolved fill: the flat colour, or the gradient layers stacked
/// over it in the order `revnixParseCssGradients` returns them (bottom first).
struct RevnixFillView: View {
    let fill: RevnixBlockFill
    let doc: PaywallBlockDoc

    var body: some View {
        switch fill {
        case let .color(colour):
            colour
        case let .gradients(layers):
            ZStack {
                ForEach(Array(layers.enumerated()), id: \.offset) { _, gradient in
                    RevnixGradientView(gradient: gradient, doc: doc)
                }
            }
        }
    }
}

// MARK: - Style application

/// Applies a BlockStyle to a view.
///
/// Every field is read independently and only when present, which is what
/// lets a design authored against a newer dashboard render here minus the one
/// effect this SDK does not know, rather than failing.
private struct BlockStyleModifier: ViewModifier {
    let style: BlockStyle?
    let doc: PaywallBlockDoc
    /// Stack children position themselves; elsewhere the offsets are inert.
    let inStack: Bool
    /// Where a paint string this build cannot read is reported. Nil when the
    /// host wired no diagnostics, which is the only case that stays silent.
    let onDiagnostic: ((String) -> Void)?

    func body(content: Content) -> some View {
        guard let s = style else { return AnyView(content) }
        var view = AnyView(content)

        // Box: padding first, then size, then the painted surface — the order
        // CSS applies them in, so a background covers its padding.
        view = AnyView(view.padding(.top, s.paddingTop ?? s.paddingY ?? s.padding ?? 0)
            .padding(.bottom, s.paddingBottom ?? s.paddingY ?? s.padding ?? 0)
            .padding(.leading, s.paddingLeft ?? s.paddingX ?? s.padding ?? 0)
            .padding(.trailing, s.paddingRight ?? s.paddingX ?? s.padding ?? 0))

        if let ratio = s.aspectRatio?.ratio {
            view = AnyView(view.aspectRatio(ratio, contentMode: .fit))
        }
        if let w = s.width?.points, let h = s.height?.points {
            view = AnyView(view.frame(width: w, height: h))
        } else {
            if let w = s.width?.points { view = AnyView(view.frame(width: w)) }
            if let h = s.height?.points { view = AnyView(view.frame(height: h)) }
        }
        if let minH = s.minHeight { view = AnyView(view.frame(minHeight: minH)) }
        if let maxW = s.maxWidth?.points { view = AnyView(view.frame(maxWidth: maxW)) }
        // A percentage width fills the axis it was given — the closest SwiftUI
        // has to a fraction of the parent without measuring it.
        if s.width?.fraction != nil { view = AnyView(view.frame(maxWidth: .infinity)) }
        // A percentage height fills likewise. A root card at `height: "100%"`
        // is what lets a design follow a taller canvas instead of leaving a
        // band under it (render contract v2 §3).
        if s.height?.fraction != nil { view = AnyView(view.frame(maxHeight: .infinity)) }
        // `inset` fills the stack it sits in on both axes (§5) — the
        // full-bleed photo and the scrim over it are both authored this way.
        if inStack, s.inset == true {
            view = AnyView(view.frame(maxWidth: .infinity, maxHeight: .infinity))
        }

        // The painted surface. A gradient reaches here as the CSS string the
        // dashboard put in `background`; it is parsed into the same layers the
        // screen background uses, so a gradient-filled card, badge or button
        // paints as designed instead of staying blank.
        if let fill = revnixBlockFill(s.fill, doc, onDiagnostic: onDiagnostic) {
            view = AnyView(view.background(RevnixFillView(fill: fill, doc: doc)))
        }
        if let radius = s.radius {
            // 9999 is the designs' "fully round" idiom.
            view = AnyView(view.clipShape(RoundedRectangle(cornerRadius: min(radius, 999))))
        }
        if let width = s.borderWidth ?? (s.borderColor != nil ? 1 : nil) {
            let colour = revnixBlockStrokeColor(s.borderColor, doc, onDiagnostic: onDiagnostic)
                ?? revnixBlockColor(doc.textColor, doc) ?? .primary
            view = AnyView(view.overlay(
                RoundedRectangle(cornerRadius: min(s.radius ?? 0, 999)).strokeBorder(colour, lineWidth: width)
            ))
        }
        // Per-side rules — table rows and editorial hairlines, which a single
        // border cannot express.
        view = AnyView(view.overlay(alignment: .top) { edge(s.borderTop) })
        view = AnyView(view.overlay(alignment: .bottom) { edge(s.borderBottom) })
        view = AnyView(view.overlay(alignment: .leading) { edge(s.borderLeft, vertical: true) })
        view = AnyView(view.overlay(alignment: .trailing) { edge(s.borderRight, vertical: true) })

        if let opacity = s.opacity { view = AnyView(view.opacity(opacity / 100)) }
        if let rotate = s.rotate { view = AnyView(view.rotationEffect(.degrees(rotate))) }
        if let shadow = s.shadow, revnixBlockColor(shadow, doc) != nil || shadow.contains("rgba") {
            view = AnyView(view.shadow(color: .black.opacity(0.25), radius: 12, y: 4))
        }
        if let z = s.zIndex { view = AnyView(view.zIndex(z)) }

        view = AnyView(view.padding(.top, s.marginTop?.points ?? s.margin ?? 0)
            .padding(.bottom, s.marginBottom?.points ?? s.margin ?? 0)
            .padding(.leading, s.marginLeft?.points ?? s.margin ?? 0)
            .padding(.trailing, s.marginRight?.points ?? s.margin ?? 0))

        // Stack placement. Percentage offsets have no fixed point value, so
        // they are left to the stack's own alignment rather than guessed.
        if inStack {
            if let top = s.top?.points { view = AnyView(view.offset(y: top)) }
            else if let bottom = s.bottom?.points { view = AnyView(view.offset(y: -bottom)) }
            if let left = s.left?.points { view = AnyView(view.offset(x: left)) }
            else if let right = s.right?.points { view = AnyView(view.offset(x: -right)) }
        }
        return view
    }

    @ViewBuilder
    private func edge(_ spec: String?, vertical: Bool = false) -> some View {
        if let spec, let colour = borderColour(spec) {
            Rectangle().fill(colour)
                .frame(width: vertical ? borderWidth(spec) : nil, height: vertical ? nil : borderWidth(spec))
        }
    }

    /// "1.5px solid @text/12" → the colour. Anything unparseable draws nothing
    /// rather than a black line the design never asked for.
    private func borderColour(_ spec: String) -> Color? {
        let parts = spec.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return revnixBlockStrokeColor(parts[2], doc, onDiagnostic: onDiagnostic)
    }

    private func borderWidth(_ spec: String) -> CGFloat {
        let first = spec.split(separator: " ").first.map(String.init) ?? "1"
        return CGFloat(Double(first.replacingOccurrences(of: "px", with: "")) ?? 1)
    }
}

private extension View {
    func revnixBlockStyle(
        _ style: BlockStyle?,
        _ doc: PaywallBlockDoc,
        inStack: Bool = false,
        diagnostic: ((String) -> Void)? = nil
    ) -> some View {
        modifier(BlockStyleModifier(style: style, doc: doc, inStack: inStack, onDiagnostic: diagnostic))
    }
}

// MARK: - Renderer

/// Everything the tree needs that is not in the document itself.
struct BlockContext {
    let doc: PaywallBlockDoc
    let packages: [RevnixPaywallPackage]
    /// The selected package — already resolved by `revnixSelectedPackageId`
    /// (host → own tap → highlight → first). It is what a plan card's
    /// `selectedStyle` answers to and what tags outside any package card
    /// resolve against.
    let selectedPackageId: String?
    /// Host `loading` (render contract v2 §4): purchase buttons disable and
    /// show a spinner in place of their label; close buttons are unaffected.
    let loading: Bool
    let heroImageUrl: String?
    let footerTermsUrl: String?
    let footerPrivacyUrl: String?
    let onPurchase: (String) -> Void
    /// Reports a plan card tap. Selection is the paywall's own state, so a
    /// design's plan cards work without the host wiring anything.
    let onSelect: (String) -> Void
    let onRestore: (() -> Void)?
    let onTerms: (() -> Void)?
    let onPrivacy: (() -> Void)?
    /// Dismissal (REV-252). Nil means the host wired none, and no close is
    /// drawn at all — a dead close button is worse than none.
    let onClose: (() -> Void)?
    let openURL: (URL) -> Void
    /// Where the renderer reports a paint string it could not read. The screen
    /// still draws — a fill falls back to a colour from the design — but the
    /// host gets told, which is what a silent black screen never did.
    var onDiagnostic: ((String) -> Void)?

    /// The package root-level copy resolves its tags against (contract §2).
    var selectedPackage: RevnixPaywallPackage? {
        packages.first { $0.packageId == selectedPackageId }
    }
}

/// Makes an element the paywall's dismiss target when the design marks it as
/// one. A block with no close action installs no gesture at all, so it never
/// swallows a tap meant for what sits behind it.
struct CloseOnTap: ViewModifier {
    let action: BlockAction?
    let onClose: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if action == .close, let onClose {
            // The whole box is the target, not just the glyph: a close chip
            // is mostly padding, and a bare × is well under the 44pt minimum.
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close")
        } else {
            content
        }
    }
}

/// The press feedback every designed button gets (render contract v2 §4):
/// 80% while the finger is down, full weight on release. Deliberately no
/// dimming while disabled — the loading state paints its own answer (the
/// spinner) and must keep the fill behind it.
struct RevnixBlockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A scroll container that scrolls only when it has to (contract §3): no
/// bounce or overscroll while the content fits the viewport. `fits` is nil
/// where the caller cannot measure; the pre-16.4 fallback then leaves
/// scrolling on rather than guess.
struct RevnixFitScroll: ViewModifier {
    let fits: Bool?

    func body(content: Content) -> some View {
        if #available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *) {
            content.scrollBounceBehavior(.basedOnSize)
        } else {
            content.scrollDisabled(fits ?? false)
        }
    }
}

/// Renders one block. Anything it cannot render contributes nothing and its
/// siblings are unaffected.
struct BlockView: View {
    let block: PaywallBlock
    let ctx: BlockContext
    /// The package this subtree describes: the nearest pinned or repeated
    /// card's. Nil outside any package card.
    var package: RevnixPaywallPackage?
    var inStack: Bool = false

    private var doc: PaywallBlockDoc { ctx.doc }

    /// Where the block stands relative to the selection (contract §1). Read
    /// off `package`, so a plain card inside a pinned one inherits its row's.
    private var context: RevnixBlockSelectionContext {
        revnixSelectionContext(package: package, selectedPackageId: ctx.selectedPackageId)
    }

    /// The package copy tags resolve against (contract §2): the enclosing
    /// card's, else the selected one — which is what turns the renewal line
    /// every template carries ("then {price}/{period_short}") into a price.
    private var tagPackage: RevnixPaywallPackage? { package ?? ctx.selectedPackage }

    /// `selectedStyle` merged over `style` in selected context, else `style`.
    private var style: BlockStyle? { revnixEffectiveStyle(block, in: context) }

    var body: some View {
        if case let .card(b) = block {
            // A card judges context per instance — a pinned card's is its own
            // package's, not its parent's — so it decides visibility itself.
            CardBlockView(block: b, ctx: ctx, package: package, inStack: inStack)
        } else if revnixIsBlockVisible(block, in: context) {
            leaf
        }
    }

    @ViewBuilder
    private var leaf: some View {
        switch block {
        case let .text(b):
            Text(revnixResolveTags(b.text, package: tagPackage, all: ctx.packages))
                .modifier(TextStyling(style: style, doc: doc, onDiagnostic: ctx.onDiagnostic))
                .revnixBlockStyle(style, doc, inStack: inStack, diagnostic: ctx.onDiagnostic)
                .modifier(CloseOnTap(action: b.action, onClose: ctx.onClose))

        case let .image(b):
            ImageBlockView(block: b, style: style, ctx: ctx, inStack: inStack)
                .modifier(CloseOnTap(action: b.action, onClose: ctx.onClose))

        case let .list(b):
            VStack(alignment: .leading, spacing: style?.gap ?? 8) {
                ForEach(Array(b.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 9) {
                        Text(item.icon ?? "✓")
                            .fontWeight(.heavy)
                            .foregroundStyle(revnixBlockStrokeColor(b.iconColor, doc, onDiagnostic: ctx.onDiagnostic)
                                ?? revnixBlockColor(doc.accent, doc) ?? .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).fontWeight(item.description == nil ? .medium : .bold)
                            if let description = item.description {
                                Text(description).font(.system(size: 12)).opacity(0.7)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .revnixBlockStyle(style, doc, inStack: inStack, diagnostic: ctx.onDiagnostic)

        case let .products(b):
            ProductsBlockView(block: b, ctx: ctx)
                .revnixBlockStyle(style, doc, inStack: inStack, diagnostic: ctx.onDiagnostic)

        case let .button(b):
            // A button the design marks as the close dismisses instead of
            // buying, and takes no accent fill: the CTA must stay the one
            // accented thing on the screen, or a "Not now" competes with
            // "Subscribe" for the eye.
            let closesPaywall = b.action == .close && ctx.onClose != nil
            // Loading disables purchasing and swaps the label for a spinner
            // (contract §4). A close button keeps working: the customer must
            // be able to leave while a purchase is in flight.
            let busy = ctx.loading && !closesPaywall
            // `strippedBox` hands the box back to us, so the fill is resolved
            // here rather than by the style modifier — which is why a gradient
            // CTA used to flatten to the plain accent.
            let buttonFill: RevnixBlockFill =
                revnixBlockFill(style?.fill, doc, onDiagnostic: ctx.onDiagnostic)
                    ?? .color(closesPaywall
                        ? .clear
                        : (revnixBlockColor(doc.accent, doc) ?? .accentColor))
            let ink = closesPaywall
                ? (revnixBlockColor(doc.textColor, doc) ?? .primary)
                : (revnixBlockColor(doc.accentInk, doc) ?? .white)
            Button {
                if closesPaywall {
                    ctx.onClose?()
                } else if !ctx.loading, let id = ctx.selectedPackageId ?? ctx.packages.first?.packageId {
                    ctx.onPurchase(id)
                }
            } label: {
                Text(revnixResolveTags(b.label, package: tagPackage, all: ctx.packages))
                    .modifier(TextStyling(style: style, doc: doc, defaultWeight: .heavy, defaultSize: 15, onDiagnostic: ctx.onDiagnostic))
                    // Hidden rather than removed, so the box keeps the size
                    // the label gave it while the spinner stands in for it.
                    .opacity(busy ? 0 : 1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, style?.height == nil ? 15 : 0)
                    .padding(.horizontal, 16)
                    .frame(height: style?.height?.points.map { CGFloat($0) })
                    .overlay {
                        if busy { ProgressView().tint(ink) }
                    }
                    .background(RevnixFillView(fill: buttonFill, doc: doc))
                    .foregroundStyle(ink)
                    .clipShape(RoundedRectangle(cornerRadius: style?.radius ?? 12))
            }
            .buttonStyle(RevnixBlockButtonStyle())
            .disabled(busy)
            .revnixBlockStyle(strippedBox(style), doc, inStack: inStack, diagnostic: ctx.onDiagnostic)

        case let .links(b):
            LinksBlockView(block: b, ctx: ctx)
                .revnixBlockStyle(style, doc, inStack: inStack, diagnostic: ctx.onDiagnostic)

        case .line:
            RevnixFillView(
                fill: revnixBlockFill(style?.fill, doc, onDiagnostic: ctx.onDiagnostic)
                    ?? .color((revnixBlockColor(doc.textColor, doc) ?? .primary).opacity(0.16)),
                doc: doc
            )
            .frame(height: style?.height?.points ?? 1)
                .revnixBlockStyle(strippedBox(style), doc, inStack: inStack, diagnostic: ctx.onDiagnostic)

        case let .spacer(b):
            if b.flex == true {
                Spacer(minLength: 0)
            } else {
                Color.clear.frame(height: style?.height?.points ?? 16)
            }

        case .card:
            // Handled in `body`, which routes every card to CardBlockView.
            EmptyView()

        case .unknown:
            // A block type from a newer dashboard: skip it, keep the screen.
            EmptyView()
        }
    }

    /// The style minus the fields the view already applied itself, so a radius
    /// or fill is not painted twice.
    private func strippedBox(_ style: BlockStyle?) -> BlockStyle? {
        guard var s = style else { return nil }
        s.fill = nil
        s.radius = nil
        s.height = nil
        return s
    }
}

/// Type styling — the fields that belong on the Text itself rather than its box.
private struct TextStyling: ViewModifier {
    let style: BlockStyle?
    let doc: PaywallBlockDoc
    var defaultWeight: Font.Weight = .regular
    var defaultSize: CGFloat = 15
    var onDiagnostic: ((String) -> Void)?

    func body(content: Content) -> some View {
        let size = CGFloat(style?.fontSize ?? Double(defaultSize))
        var view = AnyView(
            content
                .font(font(size: size))
                .foregroundStyle(revnixBlockStrokeColor(style?.textColor, doc, onDiagnostic: onDiagnostic)
                    ?? revnixBlockColor(doc.textColor, doc) ?? .primary)
        )
        // CSS letter-spacing is em; SwiftUI tracking is points.
        if let em = style?.letterSpacing { view = AnyView(view.tracking(em * size)) }
        // A unitless line-height maps onto extra spacing over the ~1.2× box.
        if let lh = style?.lineHeight { view = AnyView(view.lineSpacing(max(0, lh * size - size * 1.2))) }
        if let align = style?.align {
            view = AnyView(view.multilineTextAlignment(
                align == "center" ? .center : align == "right" ? .trailing : .leading
            ))
        }
        if style?.nowrap == true { view = AnyView(view.lineLimit(1)) }
        if style?.decoration == "underline" { view = AnyView(view.underline()) }
        if style?.decoration == "line-through" { view = AnyView(view.strikethrough()) }
        if style?.textTransform == "uppercase" { view = AnyView(view.textCase(.uppercase)) }
        return view
    }

    private func font(size: CGFloat) -> Font {
        let weight = fontWeight
        // The design's own face, when the host app has registered it. An
        // unregistered family falls back to the system face rather than
        // rendering nothing.
        if let family = style?.fontFamily ?? doc.fontFamily, !family.isEmpty {
            return .custom(family, size: size)
        }
        let base = Font.system(size: size, weight: weight)
        return style?.fontStyle == "italic" ? base.italic() : base
    }

    private var fontWeight: Font.Weight {
        switch style?.fontWeight ?? 0 {
        case 900...: return .black
        case 800 ..< 900: return .heavy
        case 700 ..< 800: return .bold
        case 600 ..< 700: return .semibold
        case 500 ..< 600: return .medium
        case 1 ..< 500: return .regular
        default: return defaultWeight
        }
    }
}

private struct ImageBlockView: View {
    let block: ImageBlock
    /// The effective style — `selectedStyle` already merged in by the caller.
    let style: BlockStyle?
    let ctx: BlockContext
    let inStack: Bool

    var body: some View {
        let url = (block.url?.isEmpty == false ? block.url : nil) ?? ctx.heroImageUrl
        let inset = inStack && style?.inset == true
        // A converted design sizes its own slot; the 160pt default is only for
        // a slot dropped into a flow column, and must not fight it.
        let sized = inset || (style.map {
            $0.height != nil || $0.aspectRatio != nil || $0.flex != nil
        } ?? false)
        let radius: CGFloat = block.shape == "circle" ? 999 : sized ? 0 : 16

        // The clear base owns the box and the photo paints over it. Laid out
        // directly, a `cover` image reports its own scaled size and pushes the
        // layout past the box it was given — the classic hero avoids that the
        // same way. An `inset` image fills its stack on both axes (contract
        // §5): the style modifier grants the size and this base accepts it.
        Color.clear
            .overlay {
                if let url, let parsed = URL(string: url) {
                    AsyncImage(url: parsed) { image in
                        image.resizable().aspectRatio(contentMode: block.fit == "contain" ? .fit : .fill)
                    } placeholder: {
                        slot
                    }
                } else {
                    slot
                }
            }
            .frame(height: sized ? nil : 160)
            .frame(maxWidth: .infinity)
            // A GPU pass over the drawn box, no decode — cheap enough to honour.
            .modifier(RevnixBlurModifier(radius: style?.blur))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .revnixBlockStyle(style, ctx.doc, inStack: inStack, diagnostic: ctx.onDiagnostic)
    }

    private var slot: some View {
        ZStack {
            Color.gray.opacity(0.22)
            if let placeholder = block.placeholder, !placeholder.isEmpty {
                Text(placeholder)
                    .font(.system(size: 10.5))
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .opacity(0.62)
            }
        }
    }
}

private struct LinksBlockView: View {
    let block: LinksBlock
    let ctx: BlockContext

    var body: some View {
        let entries = items
        if entries.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 20) {
                ForEach(entries, id: \.label) { entry in
                    Button(entry.label) { entry.action() }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12))
            .opacity(0.65)
            .frame(maxWidth: .infinity)
        }
    }

    private struct Entry { let label: String; let action: () -> Void }

    /// An explicit host handler wins over the config URL — the app knows best
    /// how to open its own legal pages; the URL is the no-handler fallback.
    private var items: [Entry] {
        var out: [Entry] = []
        if block.showRestore ?? true {
            out.append(Entry(label: "Restore") { ctx.onRestore?() })
        }
        if block.showTerms ?? true {
            let url = block.termsUrl ?? ctx.footerTermsUrl
            out.append(Entry(label: "Terms") { open(ctx.onTerms, url) })
        }
        if block.showPrivacy ?? true {
            let url = block.privacyUrl ?? ctx.footerPrivacyUrl
            out.append(Entry(label: "Privacy") { open(ctx.onPrivacy, url) })
        }
        return out
    }

    private func open(_ handler: (() -> Void)?, _ url: String?) {
        if let handler { handler(); return }
        if let url, let parsed = URL(string: url) { ctx.openURL(parsed) }
    }
}

/// Makes a card its package's selection target. A card that names no package
/// is decoration and installs no gesture at all, so it never swallows a tap
/// meant for the screen behind it.
private struct SelectOnTap: ViewModifier {
    let packageId: String?
    let onSelect: (String) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let packageId {
            // The whole card is the target, not just its glyphs — a plan row
            // is mostly padding. A child Button still wins the tap.
            content
                .contentShape(Rectangle())
                .onTapGesture { onSelect(packageId) }
        } else {
            content
        }
    }
}

private struct ProductsBlockView: View {
    let block: ProductsBlock
    let ctx: BlockContext

    var body: some View {
        let shown = ctx.packages
        let highlightId = ctx.selectedPackageId.flatMap { id in
            shown.contains(where: { $0.packageId == id }) ? id : nil
        } ?? shown.first?.packageId
        let row = block.direction == "row"
        let layout = AnyLayout(row ? AnyLayout(HStackLayout(spacing: block.style?.gap ?? 8))
            : AnyLayout(VStackLayout(spacing: block.style?.gap ?? 8)))

        layout {
            ForEach(shown) { pkg in
                card(pkg, highlighted: pkg.packageId == highlightId, row: row)
            }
        }
    }

    private func card(_ pkg: RevnixPaywallPackage, highlighted: Bool, row: Bool) -> some View {
        let doc = ctx.doc
        let accent = revnixBlockColor(doc.accent, doc) ?? .accentColor
        return VStack(alignment: row ? .center : .leading, spacing: 3) {
            Text(withFallback(block.titleTpl ?? "{title}", pkg, pkg.title))
                .font(.system(size: 14, weight: .bold))
            Text(withFallback(block.priceTpl ?? "{price}", pkg, pkg.priceLabel))
                .font(.system(size: 13))
            if highlighted, let sub = block.highlightSub {
                Text(sub).font(.system(size: 11.5)).opacity(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: row ? .center : .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(highlighted ? accent.opacity(0.12) : .clear)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(highlighted ? accent : Color.gray.opacity(0.35), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            if highlighted, let badge = block.badgeText {
                Text(badge)
                    .font(.system(size: 10, weight: .heavy))
                    .padding(.vertical, 2).padding(.horizontal, 8)
                    .background(accent)
                    .foregroundStyle(revnixBlockColor(doc.accentInk, doc) ?? .white)
                    .clipShape(Capsule())
                    .offset(x: -12, y: -9)
            }
        }
        .revnixBlockStyle(highlighted ? block.highlightStyle : block.cardStyle, doc, diagnostic: ctx.onDiagnostic)
        // The whole card is the target, not just its glyphs — a plan row is
        // mostly padding, and tapping the gap beside the price must select.
        .contentShape(Rectangle())
        .onTapGesture { ctx.onSelect(pkg.packageId) }
    }

    /// A template that resolves to nothing useful falls back to the plain
    /// value — a card must show a title and a price even if its template names
    /// a tag this SDK does not know.
    private func withFallback(_ tpl: String, _ pkg: RevnixPaywallPackage, _ fallback: String) -> String {
        let out = revnixResolveTags(tpl, package: pkg, all: ctx.packages)
        return out.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : out
    }
}

/// The container. `layout` maps onto SwiftUI's own primitives: column →
/// VStack, row → HStack, stack → ZStack, grid → LazyVGrid. Any value this SDK
/// does not know falls back to a column rather than rendering nothing.
private struct CardBlockView: View {
    let block: CardBlock
    let ctx: BlockContext
    var package: RevnixPaywallPackage?
    var inStack: Bool

    var body: some View {
        if block.repeatMode == "packages" {
            // One designed card, rendered per package. With nothing attached a
            // single instance still renders, so the design stays visible.
            let list: [RevnixPaywallPackage?] = ctx.packages.isEmpty ? [nil] : ctx.packages.map { $0 }
            ForEach(Array(list.enumerated()), id: \.offset) { _, pkg in
                instance(for: pkg, selects: pkg?.packageId)
            }
        } else if let index = block.packageIndex, !ctx.packages.indices.contains(index) {
            // A card that names a package the offering does not reach is
            // dropped rather than shown with unresolved tags.
            EmptyView()
        } else {
            let ctxPackage = block.packageIndex.map { ctx.packages[$0] }
            // A card pinned to a package doubles as its selection target —
            // that is how hand-styled plan rows (a highlighted annual beside
            // a plain monthly) become tappable without a products block. A
            // card that names no package is decoration and stays inert, and
            // inherits whatever package card it sits inside.
            instance(for: ctxPackage ?? package, selects: ctxPackage?.packageId)
        }
    }

    /// One drawn instance of the card. Its context is its OWN package's when
    /// it is pinned or repeated and the inherited one otherwise (contract §1),
    /// so a plain card inside a plan row takes that row's selection, and a
    /// pinned card decides for itself whether it is visible at all. Its
    /// `selectedStyle` is the whole of its selection feedback — no opacity
    /// on press, by design.
    @ViewBuilder
    private func instance(for pkg: RevnixPaywallPackage?, selects packageId: String?) -> some View {
        let whole = PaywallBlock.card(block)
        let context = revnixSelectionContext(package: pkg, selectedPackageId: ctx.selectedPackageId)
        if revnixIsBlockVisible(whole, in: context) {
            container(for: pkg, style: revnixEffectiveStyle(whole, in: context), selects: packageId)
        }
    }

    @ViewBuilder
    private func container(
        for pkg: RevnixPaywallPackage?,
        style: BlockStyle?,
        selects packageId: String? = nil
    ) -> some View {
        let kind = block.layout ?? "column"
        let spacing = style?.gap ?? 10
        let children = block.children

        Group {
            switch kind {
            case "row":
                HStack(alignment: crossAlignmentVertical, spacing: spacing) {
                    if style?.justify == "center" || style?.justify == "end" { Spacer(minLength: 0) }
                    childViews(children, pkg, inStack: false)
                    if style?.justify == "center" || style?.justify == "start" { Spacer(minLength: 0) }
                }
            case "stack":
                ZStack(alignment: .topLeading) {
                    childViews(children, pkg, inStack: true)
                }
            case "grid":
                LazyVGrid(columns: gridColumns, spacing: spacing) {
                    childViews(children, pkg, inStack: false)
                }
            default:
                // column, and anything unrecognized.
                VStack(alignment: crossAlignmentHorizontal, spacing: spacing) {
                    childViews(children, pkg, inStack: false)
                }
            }
        }
        .revnixBlockStyle(style, ctx.doc, inStack: inStack, diagnostic: ctx.onDiagnostic)
        .modifier(SelectOnTap(packageId: packageId, onSelect: ctx.onSelect))
    }

    @ViewBuilder
    private func childViews(_ children: [PaywallBlock], _ pkg: RevnixPaywallPackage?, inStack: Bool) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            BlockView(block: child, ctx: ctx, package: pkg, inStack: inStack)
        }
    }

    private var gridColumns: [GridItem] {
        // The design's own track list wins; `columns` is the simple form.
        if let tracks = block.gridColumns, !tracks.isEmpty {
            return tracks.split(separator: " ").map { track in
                if track.hasSuffix("px"), let n = Double(track.dropLast(2)) {
                    return GridItem(.fixed(n))
                }
                return GridItem(.flexible())
            }
        }
        return Array(repeating: GridItem(.flexible()), count: max(1, block.columns ?? 2))
    }

    private var crossAlignmentHorizontal: HorizontalAlignment {
        switch block.style?.items {
        case "center": return .center
        case "end": return .trailing
        default: return .leading
        }
    }

    private var crossAlignmentVertical: VerticalAlignment {
        switch block.style?.items {
        case "center": return .center
        case "end": return .bottom
        case "baseline": return .firstTextBaseline
        default: return .top
        }
    }
}

// MARK: - Screen

/// Renders a whole block document.
///
/// A `canvas` document is authored against a fixed 393×852 device screen and
/// is scaled as a whole, so absolute placement inside `stack` containers stays
/// true at any width. The rules are render contract v2 §3, shared with every
/// other renderer (`revnixCanvasMetrics` is the testable half):
///
///   * scale = min(width, 480) / 393 — a phone design never grows past ~1.22×
///     on a tablet or in landscape; it sits centred with the document
///     background filling the viewport around it;
///   * the layout is at least 852 design units tall and grows to fill a taller
///     viewport, so a root card at `height: "100%"` follows and nothing leaves
///     a band under the design;
///   * a shorter viewport scrolls, indicator hidden, no bounce when it fits;
///   * it is full-bleed under the status bar (the designs pad their own
///     bottom inset) while the fallback close stays inside the safe area.
///
/// A `flow` document lays out as an ordinary scrolling column.
struct RevnixPaywallBlockView: View {
    let doc: PaywallBlockDoc
    let ctx: BlockContext

    var body: some View {
        // REV-252: the close is overlaid OUTSIDE the canvas scale and inside
        // the safe area, so it keeps its tap size and its distance from the
        // screen edge whatever the device does to the design.
        ZStack(alignment: .topTrailing) {
            if doc.layout == "canvas" {
                canvas.ignoresSafeArea()
            } else {
                flow
            }
            fallbackClose
        }
        .background(screenBackground.ignoresSafeArea())
    }

    private var canvas: some View {
        GeometryReader { geo in
            let metrics = revnixCanvasMetrics(viewportWidth: geo.size.width, viewportHeight: geo.size.height)
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .frame(width: PaywallBlockDoc.canvasWidth, height: metrics.layoutHeight, alignment: .topLeading)
                    .scaleEffect(metrics.scale, anchor: .topLeading)
                    .frame(width: metrics.scaledWidth, height: metrics.scaledHeight, alignment: .topLeading)
                    .clipped()
                    .frame(maxWidth: .infinity)
            }
            .modifier(RevnixFitScroll(fits: metrics.fits))
        }
    }

    private var flow: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .modifier(RevnixFitScroll(fits: nil))
    }

    /// The dismiss affordance the renderer supplies itself (REV-252).
    ///
    /// Drawn only when the design authors no close of its own AND the host
    /// wired an `onClose` — which is what makes every paywall published before
    /// close existed dismissible without being re-authored, while a design
    /// that DOES carry a close chip never ends up showing two.
    ///
    /// Deliberately plain: it is a safety net, not a design element. Tinted
    /// from the screen's own ink rather than a fixed white, so it stays
    /// legible on a light design as well as a dark one.
    @ViewBuilder private var fallbackClose: some View {
        if let onClose = ctx.onClose, !revnixHasCloseAction(doc.blocks) {
            let ink = revnixBlockColor(doc.textColor, doc) ?? .primary
            Button(action: onClose) {
                Text(verbatim: "\u{00D7}")
                    .font(.system(size: 17))
                    .foregroundStyle(ink)
                    .frame(width: 30, height: 30)
                    .background(ink.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(14)
        }
    }

    /// The screen background: ground, then photo, then scrim — the same three
    /// layers, in the same order, as the dashboard renderer paints. A document
    /// whose background is still a plain colour resolves to a ground and
    /// nothing else, so that case renders exactly as it did before.
    @ViewBuilder private var screenBackground: some View {
        let layers = revnixBackgroundLayers(doc.backgroundSpec)
        let ground = layers.ground ?? doc.background
        ZStack {
            // The flat colour under everything. A gradient resolves to its
            // first stop here, so a form the parser does not understand still
            // shows a colour from the design rather than black.
            (revnixBlockColor(revnixBackgroundBaseColor(ground), doc) ?? .black)

            ForEach(Array(revnixParseCssGradients(ground, isColor: { revnixBlockColor($0, doc) != nil }).enumerated()), id: \.offset) { _, gradient in
                RevnixGradientView(gradient: gradient, doc: doc)
            }

            if let image = layers.image {
                RevnixBackgroundPhotoView(image: image)
            }

            if let overlay = layers.overlay {
                RevnixScrimView(overlay: overlay, doc: doc)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(doc.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, ctx: ctx)
            }
        }
    }
}

/// One parsed CSS gradient as a SwiftUI gradient.
///
/// The stops carry colour STRINGS rather than resolved colours so the palette
/// tokens inside a scrim (`@bg/40`) resolve against the same document the rest
/// of the screen uses.
struct RevnixGradientView: View {
    let gradient: RevnixGradient
    let doc: PaywallBlockDoc

    var body: some View {
        let stops = gradient.stops.map { stop in
            Gradient.Stop(
                color: revnixBlockColor(stop.color, doc) ?? .clear,
                location: stop.position
            )
        }
        switch gradient {
        case let .linear(dirX, dirY, _):
            // The direction is a unit vector scaled so its largest component is
            // 1, so half of it either side of the centre reaches the box edge —
            // the CSS gradient line.
            LinearGradient(
                stops: stops,
                startPoint: UnitPoint(x: 0.5 - dirX / 2, y: 0.5 - dirY / 2),
                endPoint: UnitPoint(x: 0.5 + dirX / 2, y: 0.5 + dirY / 2)
            )
        case let .radial(centerX, centerY, radius, _):
            GeometryReader { geo in
                RadialGradient(
                    stops: stops,
                    center: UnitPoint(x: centerX, y: centerY),
                    startRadius: 0,
                    endRadius: radius * max(geo.size.width, geo.size.height)
                )
            }
        }
    }
}

/// The screen background's photo layer.
///
/// `AsyncImage` has no `object-position`, so a focal point other than the
/// centre is drawn with a scaled fill clipped to the box — the same rule CSS
/// applies for `object-position: X% Y%`, where the X% point of the image aligns
/// to the X% point of the box. A photo that will not load leaves the ground and
/// scrim in place rather than blacking out the screen.
struct RevnixBackgroundPhotoView: View {
    let image: RevnixBackgroundImage

    @State private var source: CGSize?

    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: URL(string: image.url)) { phase in
                if let loaded = phase.image {
                    photo(loaded, in: geo.size)
                } else {
                    Color.clear
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .opacity(image.opacity)
        .modifier(RevnixBlurModifier(radius: image.blur))
        .allowsHitTesting(false)
        .task(id: image.url) { source = await revnixImageSize(image.url) }
    }

    /// `contain` and a centred `cover` need no geometry, so they take the
    /// plain resizable path and never wait on a measurement — which is also
    /// what shows while an off-centre photo's size is still being fetched, so
    /// there is no flash of a wrongly cropped image.
    @ViewBuilder
    private func photo(_ loaded: Image, in box: CGSize) -> some View {
        let centred = image.focalX == 50 && image.focalY == 50
        if image.fit == .contain || centred || source == nil {
            loaded
                .resizable()
                .aspectRatio(contentMode: image.fit == .contain ? .fit : .fill)
                .frame(width: box.width, height: box.height)
        } else {
            let placement = revnixCoverPlacement(
                box: (Double(box.width), Double(box.height)),
                source: (Double(source!.width), Double(source!.height)),
                focalX: image.focalX,
                focalY: image.focalY
            )
            loaded
                .resizable()
                .frame(width: placement.width, height: placement.height)
                .offset(x: placement.left, y: placement.top)
                .frame(width: box.width, height: box.height, alignment: .topLeading)
        }
    }
}

/// The pixel dimensions of a remote image, or nil if it cannot be measured.
///
/// `AsyncImage` hands back a SwiftUI `Image`, which has no size, so the focal
/// crop needs its own fetch. A failed measure is not an error worth surfacing:
/// the centred path above stays in place.
func revnixImageSize(_ url: String) async -> CGSize? {
    guard let url = URL(string: url) else { return nil }
    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
    #if canImport(UIKit)
    return UIImage(data: data)?.size
    #elseif canImport(AppKit)
    guard let rep = NSBitmapImageRep(data: data) else { return nil }
    return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    #else
    return nil
    #endif
}

/// A blur applied only when the design asked for one, so an unblurred photo
/// keeps its original render path.
struct RevnixBlurModifier: ViewModifier {
    let radius: Double?

    func body(content: Content) -> some View {
        if let radius, radius > 0 {
            // A blurred layer bleeds its transparent edge inward, which reads
            // as a bright rim over the ground. Scaling past the edges hides it.
            content.blur(radius: radius).scaleEffect(1.1)
        } else {
            content
        }
    }
}

/// The scrim over the photo: a solid fill or a gradient stack.
struct RevnixScrimView: View {
    let overlay: RevnixBackgroundOverlay
    let doc: PaywallBlockDoc

    var body: some View {
        let gradients = revnixParseCssGradients(
            overlay.fill,
            isColor: { revnixBlockColor($0, doc) != nil }
        )
        ZStack {
            if gradients.isEmpty {
                revnixBlockColor(overlay.fill, doc) ?? .clear
            } else {
                ForEach(Array(gradients.enumerated()), id: \.offset) { _, gradient in
                    RevnixGradientView(gradient: gradient, doc: doc)
                }
            }
        }
        .opacity(overlay.opacity)
        .allowsHitTesting(false)
    }
}
#endif
