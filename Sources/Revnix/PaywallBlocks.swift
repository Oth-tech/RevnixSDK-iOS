// The paywall block model — a portable description of a designed paywall.
//
// A paywall built in the dashboard's block builder publishes a TREE of styled
// elements on `PaywallConfig.blocks`, and that tree takes precedence over the
// classic `template` layouts. This file is the decoded model; the SwiftUI
// interpreter is in RevnixPaywallBlockView.swift.
//
// Mirrors revnix-app's src/lib/paywall-blocks/types.ts one-for-one. The two
// must stay in lockstep: the dashboard preview and this SDK renderer are two
// interpreters of the SAME document, and a field only one side knows is a
// design that ships looking different from the design that was approved.
//
// Decoding is deliberately TOTAL: nothing in this file throws on unexpected
// input. A shipped app cannot be patched from our side, so a document from a
// newer dashboard has to decode to "the parts this SDK understands" rather
// than to an error — an unknown block type becomes `.unknown` and is skipped
// at render time, leaving the rest of the screen intact.

import Foundation

// MARK: - Style

/// Per-block visual style. Everything optional — a block renders sensibly with
/// no style at all. Sizes are points; colors are any hex/rgb string, or a
/// palette token (`@accent`, `@text`, `@bg`, `@accentInk`, optionally with an
/// alpha percentage: `@text/12`).
public struct BlockStyle: Codable, Sendable, Equatable {
    public var fill: String?
    /// Sizing for a `fill` that is an image or a REPEATING gradient — the CSS
    /// `background-size` value ("cover", "24px 24px"). The grid and hatch
    /// washes several designs use are a tiled gradient, so without this they
    /// paint as one stretched stripe instead of a texture.
    public var fillSize: String?
    public var textColor: String?
    /// 0–100, like the dashboard's opacity inputs.
    public var opacity: Double?
    public var borderColor: String?
    public var borderWidth: Double?
    /// Per-side rules, as a CSS border shorthand ("1px solid @text/12").
    public var borderTop: String?
    public var borderRight: String?
    public var borderBottom: String?
    public var borderLeft: String?
    public var radius: Double?
    public var padding: Double?
    public var paddingX: Double?
    public var paddingY: Double?
    public var paddingTop: Double?
    public var paddingRight: Double?
    public var paddingBottom: Double?
    public var paddingLeft: Double?
    public var margin: Double?
    public var marginTop: BlockDimension?
    public var marginRight: BlockDimension?
    public var marginBottom: BlockDimension?
    public var marginLeft: BlockDimension?
    public var fontSize: Double?
    public var fontWeight: Double?
    /// A design font family name. Renders only when the host app has that font
    /// registered; otherwise the system face is used, so copy never vanishes.
    public var fontFamily: String?
    public var fontStyle: String?
    public var align: String?
    /// In em, like CSS. Converted to points against the block's font size.
    public var letterSpacing: Double?
    /// Unitless multiplier, like CSS.
    public var lineHeight: Double?
    public var textTransform: String?
    public var decoration: String?
    /// Line-breaking preference for headlines ("balance", "pretty").
    ///
    /// Decoded and merged so the field survives a round trip, but SwiftUI
    /// exposes no line-breaking strategy, so it does not change layout here.
    /// It is a typographic nicety — where the ragged edge falls — not a
    /// design that reads differently, which is why it is carried rather
    /// than approximated with a guess about where to break.
    public var textWrap: String?
    public var nowrap: Bool?
    /// Gap between a container's children.
    public var gap: Double?
    public var height: BlockDimension?
    public var minHeight: Double?
    public var width: BlockDimension?
    public var maxWidth: BlockDimension?
    /// Width-to-height ratio; "16/9" strings are parsed.
    public var aspectRatio: BlockDimension?
    /// flex-grow inside a row/column container.
    public var flex: Double?
    /// flex-shrink; 0 stops a row item from being squashed.
    public var shrink: Double?
    /// flex-basis in points.
    public var basis: Double?
    public var wrap: Bool?
    public var justify: String?
    public var items: String?
    public var selfAlign: String?
    public var shadow: String?
    public var blur: Double?
    /// Raw CSS clip-path — starbursts and ticket notches. Only the
    /// `polygon(...)` form the designs use is drawn; anything else is
    /// carried but not clipped.
    public var clipPath: String?
    public var rotate: Double?
    /// CSS `translate` value ("-50% 0") — the designs centre pinned badges
    /// with left:50% + translateX(-50%). Kept apart from `rotate`'s
    /// transform, and resolved against the block's OWN size, so a
    /// percentage means what CSS means by it.
    public var translate: String?
    /// Placement inside a `stack` container. `inset` fills the stack; the
    /// individual offsets pin an edge. Ignored outside a stack.
    public var inset: Bool?
    public var top: BlockDimension?
    public var right: BlockDimension?
    public var bottom: BlockDimension?
    public var left: BlockDimension?
    public var zIndex: Double?
    public var overflow: String?

    public init() {}

    /// Every field is decoded independently with `try?`: a style key whose
    /// type this SDK does not expect costs that one property, never the block.
    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        func d<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        fill = d(.fill); fillSize = d(.fillSize); textColor = d(.textColor); opacity = d(.opacity)
        borderColor = d(.borderColor); borderWidth = d(.borderWidth)
        borderTop = d(.borderTop); borderRight = d(.borderRight)
        borderBottom = d(.borderBottom); borderLeft = d(.borderLeft)
        radius = d(.radius); padding = d(.padding); paddingX = d(.paddingX); paddingY = d(.paddingY)
        paddingTop = d(.paddingTop); paddingRight = d(.paddingRight)
        paddingBottom = d(.paddingBottom); paddingLeft = d(.paddingLeft)
        margin = d(.margin); marginTop = d(.marginTop); marginRight = d(.marginRight)
        marginBottom = d(.marginBottom); marginLeft = d(.marginLeft)
        fontSize = d(.fontSize); fontWeight = d(.fontWeight); fontFamily = d(.fontFamily)
        fontStyle = d(.fontStyle); align = d(.align); letterSpacing = d(.letterSpacing)
        lineHeight = d(.lineHeight); textTransform = d(.textTransform); decoration = d(.decoration)
        textWrap = d(.textWrap); nowrap = d(.nowrap); gap = d(.gap); height = d(.height); minHeight = d(.minHeight)
        width = d(.width); maxWidth = d(.maxWidth); aspectRatio = d(.aspectRatio)
        flex = d(.flex); shrink = d(.shrink); basis = d(.basis); wrap = d(.wrap)
        justify = d(.justify); items = d(.items); selfAlign = d(.selfAlign)
        shadow = d(.shadow); blur = d(.blur); rotate = d(.rotate)
        clipPath = d(.clipPath); translate = d(.translate)
        inset = d(.inset); top = d(.top); right = d(.right); bottom = d(.bottom); left = d(.left)
        zIndex = d(.zIndex); overflow = d(.overflow)
    }

    /// Merges another style over this one, field by field — how a plan card's
    /// `selectedStyle` is applied on top of its base style.
    public func merging(_ other: BlockStyle?) -> BlockStyle {
        guard let other else { return self }
        var out = self
        if other.fill != nil { out.fill = other.fill }
        if other.fillSize != nil { out.fillSize = other.fillSize }
        if other.textColor != nil { out.textColor = other.textColor }
        if other.opacity != nil { out.opacity = other.opacity }
        if other.borderColor != nil { out.borderColor = other.borderColor }
        if other.borderWidth != nil { out.borderWidth = other.borderWidth }
        if other.borderTop != nil { out.borderTop = other.borderTop }
        if other.borderRight != nil { out.borderRight = other.borderRight }
        if other.borderBottom != nil { out.borderBottom = other.borderBottom }
        if other.borderLeft != nil { out.borderLeft = other.borderLeft }
        if other.radius != nil { out.radius = other.radius }
        if other.padding != nil { out.padding = other.padding }
        if other.paddingX != nil { out.paddingX = other.paddingX }
        if other.paddingY != nil { out.paddingY = other.paddingY }
        if other.paddingTop != nil { out.paddingTop = other.paddingTop }
        if other.paddingRight != nil { out.paddingRight = other.paddingRight }
        if other.paddingBottom != nil { out.paddingBottom = other.paddingBottom }
        if other.paddingLeft != nil { out.paddingLeft = other.paddingLeft }
        if other.margin != nil { out.margin = other.margin }
        if other.marginTop != nil { out.marginTop = other.marginTop }
        if other.marginRight != nil { out.marginRight = other.marginRight }
        if other.marginBottom != nil { out.marginBottom = other.marginBottom }
        if other.marginLeft != nil { out.marginLeft = other.marginLeft }
        if other.fontSize != nil { out.fontSize = other.fontSize }
        if other.fontWeight != nil { out.fontWeight = other.fontWeight }
        if other.fontFamily != nil { out.fontFamily = other.fontFamily }
        if other.fontStyle != nil { out.fontStyle = other.fontStyle }
        if other.align != nil { out.align = other.align }
        if other.letterSpacing != nil { out.letterSpacing = other.letterSpacing }
        if other.lineHeight != nil { out.lineHeight = other.lineHeight }
        if other.textTransform != nil { out.textTransform = other.textTransform }
        if other.decoration != nil { out.decoration = other.decoration }
        if other.textWrap != nil { out.textWrap = other.textWrap }
        if other.nowrap != nil { out.nowrap = other.nowrap }
        if other.gap != nil { out.gap = other.gap }
        if other.height != nil { out.height = other.height }
        if other.minHeight != nil { out.minHeight = other.minHeight }
        if other.width != nil { out.width = other.width }
        if other.maxWidth != nil { out.maxWidth = other.maxWidth }
        if other.aspectRatio != nil { out.aspectRatio = other.aspectRatio }
        if other.flex != nil { out.flex = other.flex }
        if other.shrink != nil { out.shrink = other.shrink }
        if other.basis != nil { out.basis = other.basis }
        if other.wrap != nil { out.wrap = other.wrap }
        if other.justify != nil { out.justify = other.justify }
        if other.items != nil { out.items = other.items }
        if other.selfAlign != nil { out.selfAlign = other.selfAlign }
        if other.shadow != nil { out.shadow = other.shadow }
        if other.blur != nil { out.blur = other.blur }
        if other.clipPath != nil { out.clipPath = other.clipPath }
        if other.rotate != nil { out.rotate = other.rotate }
        if other.translate != nil { out.translate = other.translate }
        if other.inset != nil { out.inset = other.inset }
        if other.top != nil { out.top = other.top }
        if other.right != nil { out.right = other.right }
        if other.bottom != nil { out.bottom = other.bottom }
        if other.left != nil { out.left = other.left }
        if other.zIndex != nil { out.zIndex = other.zIndex }
        if other.overflow != nil { out.overflow = other.overflow }
        return out
    }
}

/// A length the design may write either as a number of points or as a CSS
/// string ("50%", "auto", "16/9"). Kept as both so a percentage survives
/// decoding instead of being dropped for not being a number.
public enum BlockDimension: Codable, Sendable, Equatable {
    case points(Double)
    case text(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .points(n) } else if let s = try? c.decode(String.self) {
            self = .text(s)
        } else {
            self = .text("")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .points(n): try c.encode(n)
        case let .text(s): try c.encode(s)
        }
    }

    /// The value in points, when it is one. A percentage has no fixed point
    /// value, so it resolves to nil and the caller leaves that axis to the
    /// layout — which is closer to the design than guessing a number.
    public var points: Double? {
        switch self {
        case let .points(n): return n
        case let .text(s):
            if s.hasSuffix("px"), let n = Double(s.dropLast(2)) { return n }
            return nil
        }
    }

    /// The value as a fraction of the parent, when written as a percentage.
    public var fraction: Double? {
        if case let .text(s) = self, s.hasSuffix("%"), let n = Double(s.dropLast()) { return n / 100 }
        return nil
    }

    public var isAuto: Bool {
        if case let .text(s) = self { return s == "auto" }
        return false
    }

    /// An aspect ratio, from either a number or a "16/9" string.
    public var ratio: Double? {
        switch self {
        case let .points(n): return n > 0 ? n : nil
        case let .text(s):
            let parts = s.split(separator: "/")
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), h != 0 { return w / h }
            return Double(s)
        }
    }
}

// MARK: - Blocks

/// What tapping a block does. Nil means the block is decoration.
///
/// A FIELD on the existing block types rather than a new block type: an SDK
/// older than this one drops the field and still renders the element exactly
/// as it does today, so a design carrying a close chip degrades to inert. A
/// new block type would have decoded to `.unknown` and vanished from the
/// screen instead — worse than the bug this fixes.
public enum BlockAction: String, Sendable, Equatable {
    case close
}

/// When a block is drawn, relative to the package card it sits inside (render
/// contract v2, REV-262).
///
/// `selected` draws the block only while its nearest package-bearing ancestor
/// — a pinned or repeated card — describes the selected package; `unselected`
/// only while it does not; absent means always. Outside any package card the
/// field is ignored and the block is always drawn: never hide a root-level
/// block. See `revnixIsBlockVisible`.
public enum BlockVisibility: String, Sendable, Equatable {
    case selected
    case unselected
}

public struct TextBlock: Sendable, Equatable {
    public var id: String
    public var text: String
    /// Tapping this block dismisses the paywall. See `BlockAction`.
    public var action: BlockAction?
    public var style: BlockStyle?
    /// Merged over `style` while the block is in selected context — inside a
    /// pinned or repeated card whose package is the selected one. Valid on
    /// every block type (render contract v2).
    public var selectedStyle: BlockStyle?
    /// Drawn only in the matching context; nil is always. See `BlockVisibility`.
    public var visibility: BlockVisibility?
}

public struct ImageBlock: Sendable, Equatable {
    public var id: String
    /// Empty falls back to the config's hero image, then to a blank slot.
    public var url: String?
    public var shape: String?
    public var fit: String?
    public var placeholder: String?
    /// Tapping this block dismisses the paywall. See `BlockAction`.
    public var action: BlockAction?
    public var style: BlockStyle?
    /// Merged over `style` while the block is in selected context — inside a
    /// pinned or repeated card whose package is the selected one. Valid on
    /// every block type (render contract v2).
    public var selectedStyle: BlockStyle?
    /// Drawn only in the matching context; nil is always. See `BlockVisibility`.
    public var visibility: BlockVisibility?
}

public struct ListItem: Codable, Sendable, Equatable {
    public var icon: String?
    public var title: String
    public var description: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) as? String ?? ""
        description = try? c.decodeIfPresent(String.self, forKey: .description)
    }
}

public struct ListBlock: Sendable, Equatable {
    public var id: String
    public var items: [ListItem]
    /// Icon color; defaults to the screen accent.
    public var iconColor: String?
    public var style: BlockStyle?
    /// Merged over `style` while the block is in selected context — inside a
    /// pinned or repeated card whose package is the selected one. Valid on
    /// every block type (render contract v2).
    public var selectedStyle: BlockStyle?
    /// Drawn only in the matching context; nil is always. See `BlockVisibility`.
    public var visibility: BlockVisibility?
}

/// Renders the attached offering's packages as selectable cards.
public struct ProductsBlock: Sendable, Equatable {
    public var id: String
    public var direction: String?
    public var titleTpl: String?
    public var priceTpl: String?
    public var highlightSub: String?
    public var badgeText: String?
    public var cardStyle: BlockStyle?
    public var highlightStyle: BlockStyle?
    public var style: BlockStyle?
    /// Merged over `style` while the block is in selected context — inside a
    /// pinned or repeated card whose package is the selected one. Valid on
    /// every block type (render contract v2).
    public var selectedStyle: BlockStyle?
    /// Drawn only in the matching context; nil is always. See `BlockVisibility`.
    public var visibility: BlockVisibility?
}

public struct ButtonBlock: Sendable, Equatable {
    public var id: String
    public var label: String
    /// `.close` turns this button into a dismiss ("Not now") instead of the
    /// purchase CTA, which is what a button means by default.
    public var action: BlockAction?
    public var style: BlockStyle?
    /// Merged over `style` while the block is in selected context — inside a
    /// pinned or repeated card whose package is the selected one. Valid on
    /// every block type (render contract v2).
    public var selectedStyle: BlockStyle?
    /// Drawn only in the matching context; nil is always. See `BlockVisibility`.
    public var visibility: BlockVisibility?
}

public struct LinksBlock: Sendable, Equatable {
    public var id: String
    public var showRestore: Bool?
    public var showTerms: Bool?
    public var showPrivacy: Bool?
    public var termsUrl: String?
    public var privacyUrl: String?
    public var style: BlockStyle?
    /// Merged over `style` while the block is in selected context — inside a
    /// pinned or repeated card whose package is the selected one. Valid on
    /// every block type (render contract v2).
    public var selectedStyle: BlockStyle?
    /// Drawn only in the matching context; nil is always. See `BlockVisibility`.
    public var visibility: BlockVisibility?
}

public struct LineBlock: Sendable, Equatable {
    public var id: String
    public var style: BlockStyle?
    /// Merged over `style` while the block is in selected context — inside a
    /// pinned or repeated card whose package is the selected one. Valid on
    /// every block type (render contract v2).
    public var selectedStyle: BlockStyle?
    /// Drawn only in the matching context; nil is always. See `BlockVisibility`.
    public var visibility: BlockVisibility?
}

public struct SpacerBlock: Sendable, Equatable {
    public var id: String
    /// Grows to push what follows to the bottom.
    public var flex: Bool?
    public var style: BlockStyle?
    /// Merged over `style` while the block is in selected context — inside a
    /// pinned or repeated card whose package is the selected one. Valid on
    /// every block type (render contract v2).
    public var selectedStyle: BlockStyle?
    /// Drawn only in the matching context; nil is always. See `BlockVisibility`.
    public var visibility: BlockVisibility?
}

/// The one container block. `layout` picks how children are placed: column /
/// row are flex lines, `stack` layers them (children position with
/// style.inset or the edge offsets), and `grid` is an N-column grid — which
/// map onto SwiftUI's VStack / HStack / ZStack / LazyVGrid.
public struct CardBlock: Sendable, Equatable {
    public var id: String
    public var layout: String?
    /// Renders this container once per package in the attached offering.
    public var repeatMode: String?
    /// Merged over `style` on the package the customer has selected.
    public var selectedStyle: BlockStyle?
    /// Drawn only in the matching context; nil is always. See `BlockVisibility`.
    public var visibility: BlockVisibility?
    /// "This card describes package N of the offering". A card whose index the
    /// offering does not reach is hidden.
    public var packageIndex: Int?
    /// grid only; defaults to 2.
    public var columns: Int?
    /// grid only — a CSS track list ("1fr 60px 66px").
    public var gridColumns: String?
    public var children: [PaywallBlock]
    public var style: BlockStyle?}

/// One node of the tree.
///
/// `.unknown` is the whole point of this being an enum with a catch-all: a
/// block type introduced after this SDK shipped decodes to `.unknown` and is
/// skipped by the renderer, so the screen loses that one element rather than
/// failing to decode.
public indirect enum PaywallBlock: Sendable, Equatable {
    case text(TextBlock)
    case image(ImageBlock)
    case list(ListBlock)
    case products(ProductsBlock)
    case button(ButtonBlock)
    case links(LinksBlock)
    case line(LineBlock)
    case spacer(SpacerBlock)
    case card(CardBlock)
    case unknown
}

extension PaywallBlock: Decodable {
    private enum Keys: String, CodingKey {
        case id, type, text, url, shape, fit, placeholder, style, items, iconColor, action
        case direction, titleTpl, priceTpl, highlightSub, badgeText, cardStyle, highlightStyle
        case label, showRestore, showTerms, showPrivacy, termsUrl, privacyUrl
        case flex, layout, `repeat`, selectedStyle, packageIndex, columns, gridColumns, children
        case visibility
    }

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self),
              let type = try? c.decodeIfPresent(String.self, forKey: .type)
        else {
            self = .unknown
            return
        }
        let id = (try? c.decodeIfPresent(String.self, forKey: .id)) as? String ?? ""
        let style = try? c.decodeIfPresent(BlockStyle.self, forKey: .style)
        func string(_ key: Keys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func bool(_ key: Keys) -> Bool? { (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil }
        func styleAt(_ key: Keys) -> BlockStyle? { (try? c.decodeIfPresent(BlockStyle.self, forKey: key)) ?? nil }
        // An action value this SDK does not know decodes to nil, leaving the
        // element inert rather than failing the block — the same forgiveness
        // the unknown-type catch-all gives.
        let action = string(.action).flatMap(BlockAction.init(rawValue:))
        // Render contract v2: both fields are valid on EVERY block type. A
        // visibility value this SDK does not know decodes to nil — always
        // drawn — for the same reason an unknown action decodes to inert.
        let selectedStyle = styleAt(.selectedStyle)
        let visibility = string(.visibility).flatMap(BlockVisibility.init(rawValue:))

        switch type {
        case "text":
            self = .text(TextBlock(
                id: id, text: string(.text) ?? "", action: action, style: style,
                selectedStyle: selectedStyle, visibility: visibility
            ))
        case "image":
            self = .image(ImageBlock(
                id: id, url: string(.url), shape: string(.shape), fit: string(.fit),
                placeholder: string(.placeholder), action: action, style: style,
                selectedStyle: selectedStyle, visibility: visibility
            ))
        case "list":
            let items = (try? c.decodeIfPresent([ListItem].self, forKey: .items)) as? [ListItem] ?? []
            self = .list(ListBlock(
                id: id, items: items, iconColor: string(.iconColor), style: style,
                selectedStyle: selectedStyle, visibility: visibility
            ))
        case "products":
            self = .products(ProductsBlock(
                id: id, direction: string(.direction), titleTpl: string(.titleTpl),
                priceTpl: string(.priceTpl), highlightSub: string(.highlightSub),
                badgeText: string(.badgeText), cardStyle: styleAt(.cardStyle),
                highlightStyle: styleAt(.highlightStyle), style: style,
                selectedStyle: selectedStyle, visibility: visibility
            ))
        case "button":
            self = .button(ButtonBlock(
                id: id, label: string(.label) ?? "", action: action, style: style,
                selectedStyle: selectedStyle, visibility: visibility
            ))
        case "links":
            self = .links(LinksBlock(
                id: id, showRestore: bool(.showRestore), showTerms: bool(.showTerms),
                showPrivacy: bool(.showPrivacy), termsUrl: string(.termsUrl),
                privacyUrl: string(.privacyUrl), style: style,
                selectedStyle: selectedStyle, visibility: visibility
            ))
        case "line":
            self = .line(LineBlock(id: id, style: style, selectedStyle: selectedStyle, visibility: visibility))
        case "spacer":
            self = .spacer(SpacerBlock(
                id: id, flex: bool(.flex), style: style,
                selectedStyle: selectedStyle, visibility: visibility
            ))
        case "card":
            let children = (try? c.decodeIfPresent([PaywallBlock].self, forKey: .children)) as? [PaywallBlock] ?? []
            let columns = (try? c.decodeIfPresent(Int.self, forKey: .columns)) as? Int
            let index = (try? c.decodeIfPresent(Int.self, forKey: .packageIndex)) as? Int
            self = .card(CardBlock(
                id: id, layout: string(.layout), repeatMode: string(.repeat),
                selectedStyle: selectedStyle, visibility: visibility, packageIndex: index,
                columns: columns, gridColumns: string(.gridColumns),
                children: children, style: style
            ))
        default:
            // A block type from a newer dashboard. Skipped at render time.
            self = .unknown
        }
    }

    /// The block's own style, whatever kind it is.
    public var style: BlockStyle? {
        switch self {
        case let .text(b): return b.style
        case let .image(b): return b.style
        case let .list(b): return b.style
        case let .products(b): return b.style
        case let .button(b): return b.style
        case let .links(b): return b.style
        case let .line(b): return b.style
        case let .spacer(b): return b.style
        case let .card(b): return b.style
        case .unknown: return nil
        }
    }

    /// The style merged over `style` in selected context, whatever kind it is.
    public var selectedStyle: BlockStyle? {
        switch self {
        case let .text(b): return b.selectedStyle
        case let .image(b): return b.selectedStyle
        case let .list(b): return b.selectedStyle
        case let .products(b): return b.selectedStyle
        case let .button(b): return b.selectedStyle
        case let .links(b): return b.selectedStyle
        case let .line(b): return b.selectedStyle
        case let .spacer(b): return b.selectedStyle
        case let .card(b): return b.selectedStyle
        case .unknown: return nil
        }
    }

    /// The block's visibility rule, whatever kind it is.
    public var visibility: BlockVisibility? {
        switch self {
        case let .text(b): return b.visibility
        case let .image(b): return b.visibility
        case let .list(b): return b.visibility
        case let .products(b): return b.visibility
        case let .button(b): return b.visibility
        case let .links(b): return b.visibility
        case let .line(b): return b.visibility
        case let .spacer(b): return b.visibility
        case let .card(b): return b.visibility
        case .unknown: return nil
        }
    }

    public var id: String {
        switch self {
        case let .text(b): return b.id
        case let .image(b): return b.id
        case let .list(b): return b.id
        case let .products(b): return b.id
        case let .button(b): return b.id
        case let .links(b): return b.id
        case let .line(b): return b.id
        case let .spacer(b): return b.id
        case let .card(b): return b.id
        case .unknown: return ""
        }
    }
}

// MARK: - Raw JSON

/// A verbatim JSON value.
///
/// The decoded model only covers what this SDK renders, so re-encoding from it
/// would quietly DROP any field a newer dashboard added — and a config that
/// round-trips through the SDK (cached to disk, handed back to the app) would
/// come out smaller than it went in. The original document is kept alongside
/// the model and is what gets encoded, so the trip is lossless.
public enum RevnixJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RevnixJSONValue])
    case object([String: RevnixJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([RevnixJSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: RevnixJSONValue].self) { self = .object(v) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }
}

// MARK: - Document

/// The published document: screen palette plus the block tree.
public struct PaywallBlockDoc: Codable, Sendable, Equatable {
    public var version: Int
    /// "canvas" designs are authored against a fixed device screen and scale
    /// as a whole; "flow" designs lay out in a scrolling column.
    public var layout: String?
    /// The ground paint — a color or a CSS gradient string. Kept flat because
    /// it is what `@bg` resolves against and what every unedited paywall has.
    public var background: String
    /// The background exactly as published, so the photo and scrim layers can
    /// be resolved. Nil for a document whose background is a plain string.
    public var backgroundSpec: RevnixJSONValue?
    public var textColor: String
    public var accent: String
    public var accentInk: String
    public var fontFamily: String?
    public var blocks: [PaywallBlock]
    /// The document exactly as it was published, used for re-encoding.
    public var raw: RevnixJSONValue

    /// The device screen `canvas` designs are authored against.
    public static let canvasWidth: Double = 393
    public static let canvasHeight: Double = 852

    private enum Keys: String, CodingKey {
        case version, layout, background, textColor, accent, accentInk, fontFamily, blocks
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }

    public init(from decoder: Decoder) throws {
        raw = (try? RevnixJSONValue(from: decoder)) ?? .null
        let c = try decoder.container(keyedBy: Keys.self)
        // A document with no blocks is not a design; refusing it here is what
        // makes the caller fall back to the classic layouts.
        guard let blocks = try? c.decode([PaywallBlock].self, forKey: .blocks), !blocks.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .blocks, in: c, debugDescription: "no blocks")
        }
        self.blocks = blocks
        version = ((try? c.decodeIfPresent(Int.self, forKey: .version)) as? Int) ?? 1
        layout = try? c.decodeIfPresent(String.self, forKey: .layout)
        // `background` is a plain string in the original form and an object in
        // the layered one. The object's ground field is `color` — `ground` is
        // the name of the RESOLVED layer, and reading that off the wire is what
        // used to paint every edited paywall black.
        let spec = try? c.decodeIfPresent(RevnixJSONValue.self, forKey: .background)
        backgroundSpec = spec
        background = revnixBackgroundGround(spec) ?? "#000000"
        textColor = ((try? c.decodeIfPresent(String.self, forKey: .textColor)) as? String) ?? "#FFFFFF"
        accent = ((try? c.decodeIfPresent(String.self, forKey: .accent)) as? String) ?? "#6478ff"
        accentInk = ((try? c.decodeIfPresent(String.self, forKey: .accentInk)) as? String) ?? "#FFFFFF"
        fontFamily = try? c.decodeIfPresent(String.self, forKey: .fontFamily)
    }
}

/// Does this tree author a dismiss affordance that is CERTAIN to render?
///
/// The renderer draws its own close button only when this is false, so a
/// design published before close existed becomes dismissible without being
/// re-authored, and a design that DOES author a close chip never shows two.
/// The same predicate exists in every Revnix SDK — keep them identical.
///
/// Conditional containers are deliberately not searched: a `repeat` card
/// renders once per package (none, when the offering is empty) and a
/// `packageIndex` card is hidden when the offering does not reach that index,
/// so a close authored inside one MIGHT not appear. Counting it would
/// suppress the fallback and leave the customer with no way out — the exact
/// bug this feature exists to fix. Two close buttons is merely ugly, so the
/// tie breaks toward always having one.
///
/// A block with `visibility` set is skipped for the same reason: it is drawn
/// only in one selection state, so a close authored on it is conditional too
/// (render contract v2 §1).
public func revnixHasCloseAction(_ blocks: [PaywallBlock]) -> Bool {
    blocks.contains { block in
        guard block.visibility == nil else { return false }
        switch block {
        case let .text(b): return b.action == .close
        case let .image(b): return b.action == .close
        case let .button(b): return b.action == .close
        case let .card(b):
            guard b.repeatMode == nil, b.packageIndex == nil else { return false }
            return revnixHasCloseAction(b.children)
        default: return false
        }
    }
}
