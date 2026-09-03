// PaywallRenderRules — the designed-paywall render contract v2 (REV-262) as
// pure functions.
//
// Every renderer of a `PaywallBlockDoc` — the dashboard preview, React
// Native, iOS, Android, Flutter, Unity, Capacitor — must draw the same
// document the same way. The rules that decide WHAT to draw (which package is
// selected, which blocks are in selected context, which are visible, what a
// tag resolves to, how a canvas scales) live here, away from SwiftUI, so the
// SwiftUI interpreter applies them per block and the test suite walks the
// shared cross-repo fixture (`paywall-selection-wire.json`) through the very
// same functions. A rule that only existed inside a view body could not be
// checked against that fixture, which is how the six renderers drifted.

#if canImport(SwiftUI)
import Foundation

// MARK: - Selected package

/// The package a designed paywall treats as selected (contract §1).
///
/// Host `selectedPackageId` → the renderer's own selection after a tap →
/// `config.highlightPackageId` → the first package, each step taken only if
/// it names a package the offering actually contains. The dashboard preview
/// applies the same rule with its highlight (it has no taps), so a design
/// that leans on `selectedStyle` looks in the app the way it was approved.
public func revnixSelectedPackageId(
    host: String?,
    internal internalSelection: String?,
    highlight: String?,
    packages: [RevnixPaywallPackage]
) -> String? {
    func offered(_ id: String?) -> String? {
        guard let id, packages.contains(where: { $0.packageId == id }) else { return nil }
        return id
    }
    return offered(host) ?? offered(internalSelection) ?? offered(highlight) ?? packages.first?.packageId
}

// MARK: - Selected context

/// Where a block stands relative to the selection (contract §1).
public enum RevnixBlockSelectionContext: Sendable, Equatable {
    /// Not inside any pinned or repeated card. `selectedStyle` and
    /// `visibility` are ignored here: a root-level block is always drawn.
    case outsidePackage
    /// Inside a package card whose package is the selected one.
    case selected
    /// Inside a package card whose package is not the selected one.
    case unselected
}

/// The context a block takes from its nearest package-bearing ancestor —
/// `package` is that ancestor's package, nil when there is no such ancestor.
/// A pinned or repeated card passes its OWN package here, so it judges
/// itself; everything under it inherits.
public func revnixSelectionContext(
    package: RevnixPaywallPackage?,
    selectedPackageId: String?
) -> RevnixBlockSelectionContext {
    guard let package else { return .outsidePackage }
    return package.packageId == selectedPackageId ? .selected : .unselected
}

/// The style a block draws with: `selectedStyle` merged over `style` (other
/// wins, field by field) in selected context, the plain `style` anywhere else.
public func revnixEffectiveStyle(
    _ block: PaywallBlock,
    in context: RevnixBlockSelectionContext
) -> BlockStyle? {
    guard context == .selected, let selected = block.selectedStyle else { return block.style }
    return (block.style ?? BlockStyle()).merging(selected)
}

/// Whether a block is drawn in this context. A block outside any package card
/// is drawn whatever its `visibility` says — never hide a root-level block.
public func revnixIsBlockVisible(
    _ block: PaywallBlock,
    in context: RevnixBlockSelectionContext
) -> Bool {
    guard let visibility = block.visibility else { return true }
    switch context {
    case .outsidePackage: return true
    case .selected: return visibility == .selected
    case .unselected: return visibility == .unselected
    }
}

// MARK: - The resolved tree

/// One block as the renderer would draw it for a given selection.
public struct RevnixResolvedBlock: Sendable, Equatable {
    public let id: String
    public let context: RevnixBlockSelectionContext
    /// The package its copy tags resolve against (contract §2): the enclosing
    /// package card's, else the selected one.
    public let package: RevnixPaywallPackage?
    /// `selectedStyle` merged in where the context calls for it.
    public let style: BlockStyle?
    public let visible: Bool
    /// The copy after tags, for text and button blocks; nil for the rest.
    public let text: String?
}

/// Walks a document the way the renderer does and reports what every block
/// resolves to — context, effective style, visibility, copy — without drawing
/// anything. This is the testable half of the contract: the SwiftUI
/// interpreter applies the same four functions above per block.
///
/// A `repeat` card contributes one entry per package (all sharing the card's
/// id; one entry with no package when the offering is empty). A pinned card
/// the offering does not reach contributes nothing, exactly as it draws
/// nothing. The children of a hidden block are listed as hidden too.
public func revnixResolveBlockTree(
    _ doc: PaywallBlockDoc,
    packages: [RevnixPaywallPackage],
    selectedPackageId: String?
) -> [RevnixResolvedBlock] {
    let selectedPackage = packages.first { $0.packageId == selectedPackageId }
    var out: [RevnixResolvedBlock] = []

    func visit(_ block: PaywallBlock, inherited: RevnixPaywallPackage?, hidden: Bool) {
        if case let .card(card) = block {
            if card.repeatMode == "packages" {
                let instances: [RevnixPaywallPackage?] = packages.isEmpty ? [nil] : packages.map { $0 }
                for package in instances { visitCard(card, block, package: package, hidden: hidden) }
            } else if let index = card.packageIndex {
                guard packages.indices.contains(index) else { return }
                visitCard(card, block, package: packages[index], hidden: hidden)
            } else {
                visitCard(card, block, package: inherited, hidden: hidden)
            }
            return
        }
        let context = revnixSelectionContext(package: inherited, selectedPackageId: selectedPackageId)
        let tagPackage = inherited ?? selectedPackage
        let text: String?
        switch block {
        case let .text(b): text = revnixResolveTags(b.text, package: tagPackage, all: packages)
        case let .button(b): text = revnixResolveTags(b.label, package: tagPackage, all: packages)
        default: text = nil
        }
        out.append(RevnixResolvedBlock(
            id: block.id, context: context, package: tagPackage,
            style: revnixEffectiveStyle(block, in: context),
            visible: !hidden && revnixIsBlockVisible(block, in: context),
            text: text
        ))
    }

    func visitCard(_ card: CardBlock, _ block: PaywallBlock, package: RevnixPaywallPackage?, hidden: Bool) {
        let context = revnixSelectionContext(package: package, selectedPackageId: selectedPackageId)
        let visible = !hidden && revnixIsBlockVisible(block, in: context)
        out.append(RevnixResolvedBlock(
            id: card.id, context: context, package: package ?? selectedPackage,
            style: revnixEffectiveStyle(block, in: context), visible: visible, text: nil
        ))
        for child in card.children { visit(child, inherited: package, hidden: !visible) }
    }

    for block in doc.blocks { visit(block, inherited: nil, hidden: false) }
    return out
}

// MARK: - Canvas

/// How a `canvas` document (authored at 393×852) fits a viewport (contract §3).
public struct RevnixCanvasMetrics: Sendable, Equatable {
    /// Uniform scale, by width, capped so a phone design never grows past the
    /// 480pt tablet/landscape rule (~1.22×).
    public let scale: Double
    /// The layout height in DESIGN units: at least the authored 852, more when
    /// the viewport is taller than the design at this scale — a taller screen
    /// fills, it never leaves a band.
    public let layoutHeight: Double
    /// Whether the scaled design fits the viewport without scrolling.
    public let fits: Bool

    public var scaledWidth: Double { PaywallBlockDoc.canvasWidth * scale }
    public var scaledHeight: Double { layoutHeight * scale }
}

/// The 480pt width past which a canvas design stops growing.
public let revnixCanvasMaxScaledWidth: Double = 480

public func revnixCanvasMetrics(viewportWidth: Double, viewportHeight: Double) -> RevnixCanvasMetrics {
    // A GeometryReader can report a zero size on its first pass; 1:1 there
    // rather than a division by zero.
    let width = viewportWidth > 0 ? viewportWidth : PaywallBlockDoc.canvasWidth
    let scale = min(width, revnixCanvasMaxScaledWidth) / PaywallBlockDoc.canvasWidth
    let layoutHeight = max(PaywallBlockDoc.canvasHeight, max(viewportHeight, 0) / scale)
    // Half a point of slack: the scaled height is a product of two floats and
    // "fits exactly" must not read as "scrolls by a hair".
    let fits = layoutHeight * scale <= viewportHeight + 0.5
    return RevnixCanvasMetrics(scale: scale, layoutHeight: layoutHeight, fits: fits)
}
#endif
