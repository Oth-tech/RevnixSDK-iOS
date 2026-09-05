// Geometry paint strings — the block style fields whose value is a small piece
// of CSS geometry rather than a number.
//
// `clipPath`, `translate` and `fillSize` were decoded by neither this SDK nor
// the Kotlin one: `BlockStyle` named no such properties, so `init(from:)`
// dropped them and the renderer never saw them. 13 of the 25 shipped template
// categories set at least one, which meant a starburst badge rendered as a
// rectangle, a pinned "MOST POPULAR" chip sat half a width off centre, and a
// tiled grid wash painted as one stretched stripe — all silently, and all
// only on device, never in the dashboard preview the design was approved in.
//
// Everything here is a PURE parser over a string plus a `Shape`/`ViewModifier`
// that consumes it, so the hard part is testable without a UI host. Parsing is
// total in the same way the rest of the block model is: an unreadable value
// yields nil and the block renders unclipped and unmoved, never wrong and
// never crashed.

import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - Lengths

/// A CSS `<length-percentage>`, kept as both halves so one type covers every
/// form the designs use: `16px` is points alone, `50%` is a fraction alone,
/// and `calc(100% - 16px)` — which the ticket-notch clips need — is the two
/// together. Resolving is then a single multiply-add against the box.
public struct RevnixLength: Sendable, Equatable {
    /// Fraction of the reference box on this axis: `50%` → 0.5.
    public var fraction: Double
    /// Fixed points added after the fraction: `calc(100% - 16px)` → -16.
    public var points: Double

    public init(fraction: Double = 0, points: Double = 0) {
        self.fraction = fraction
        self.points = points
    }

    /// This length against a box edge of `extent` points.
    public func resolved(against extent: Double) -> Double {
        fraction * extent + points
    }

    /// True when the value needs no measuring — a pure-points length can be
    /// applied without a GeometryReader, which keeps the common case cheap.
    public var isAbsolute: Bool { fraction == 0 }
}

/// One `<length-percentage>` token: `50%`, `-8px`, a bare `0`, or the
/// `calc(<pct> ± <px>)` form. Returns nil for anything else — a `var()`, an
/// unsupported unit — so the caller can decline the whole value rather than
/// clip against a number it guessed.
public func revnixParseLength(_ token: String) -> RevnixLength? {
    let raw = token.trimmingCharacters(in: .whitespaces)
    if raw.isEmpty { return nil }

    // calc(100% - 16px) / calc(50% + 4px). Only the single-operator form the
    // designs actually write; nested arithmetic is declined, not approximated.
    if raw.lowercased().hasPrefix("calc(") && raw.hasSuffix(")") {
        let inner = String(raw.dropFirst(5).dropLast())
        // Split on the +/- that separates the two terms. A leading sign
        // belongs to the first term, so the scan starts at index 1.
        let chars = Array(inner)
        for i in 1 ..< max(chars.count, 1) {
            let c = chars[i]
            guard c == "+" || c == "-" else { continue }
            // An operator in CSS `calc` must be surrounded by whitespace,
            // which is also what stops `1e-3` from splitting here.
            guard i > 0, chars[i - 1] == " " else { continue }
            let lhs = String(chars[..<i])
            let rhs = String(chars[(i + 1)...])
            guard let a = revnixParseLength(lhs), let b = revnixParseLength(rhs) else { return nil }
            let sign: Double = c == "-" ? -1 : 1
            return RevnixLength(fraction: a.fraction + sign * b.fraction,
                                points: a.points + sign * b.points)
        }
        return revnixParseLength(inner)
    }

    if raw.hasSuffix("%") {
        guard let n = Double(raw.dropLast()) else { return nil }
        return RevnixLength(fraction: n / 100, points: 0)
    }
    if raw.lowercased().hasSuffix("px") {
        guard let n = Double(raw.dropLast(2)) else { return nil }
        return RevnixLength(fraction: 0, points: n)
    }
    // A bare number is points, which is how the designs write `0`.
    guard let n = Double(raw) else { return nil }
    return RevnixLength(fraction: 0, points: n)
}

/// Splits on `separator` at PAREN DEPTH ZERO, so the spaces and commas inside
/// `calc(100% - 16px)` stay part of their token. Every parser below needs
/// this; splitting naively is exactly how a calc-bearing polygon would turn
/// into garbage points.
func revnixSplitTopLevel(_ value: String, on separator: Character) -> [String] {
    var out: [String] = []
    var current = ""
    var depth = 0
    for ch in value {
        switch ch {
        case "(": depth += 1; current.append(ch)
        case ")": depth = max(0, depth - 1); current.append(ch)
        case separator where depth == 0:
            out.append(current)
            current = ""
        default: current.append(ch)
        }
    }
    out.append(current)
    return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

// MARK: - translate

/// A parsed CSS `translate`: an x and a y, each of which may be a percentage
/// OF THE BLOCK'S OWN SIZE. That "own size" is the whole point — the designs
/// centre a pinned badge with `left: 50%` plus `translate: "-50% 0"`, and
/// resolving the -50% against anything but the badge's own width puts it
/// somewhere else entirely.
public struct RevnixTranslate: Sendable, Equatable {
    public var x: RevnixLength
    public var y: RevnixLength

    public init(x: RevnixLength, y: RevnixLength) {
        self.x = x
        self.y = y
    }

    /// True when neither axis needs the block measured.
    public var isAbsolute: Bool { x.isAbsolute && y.isAbsolute }
}

/// `"-50% 0"` / `"0 -8px"` / `"12px"`. A single component sets x and leaves y
/// at zero, as CSS does.
public func revnixParseTranslate(_ css: String?) -> RevnixTranslate? {
    guard let css, !css.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let parts = revnixSplitTopLevel(css, on: " ")
    guard !parts.isEmpty, parts.count <= 3 else { return nil }
    guard let x = revnixParseLength(parts[0]) else { return nil }
    // A third component is the z axis, which is meaningless in this 2D
    // renderer; the x/y prefix is still honoured rather than dropped.
    let y = parts.count > 1 ? revnixParseLength(parts[1]) : RevnixLength()
    guard let y else { return nil }
    return RevnixTranslate(x: x, y: y)
}

// MARK: - clip-path

/// One polygon vertex, each axis resolved against its own edge of the box.
public struct RevnixPolygonPoint: Sendable, Equatable {
    public var x: RevnixLength
    public var y: RevnixLength

    public init(x: RevnixLength, y: RevnixLength) {
        self.x = x
        self.y = y
    }
}

/// `polygon(50% 0,100% 100%,0 100%)` → its vertices.
///
/// Only the `polygon()` form is read. It is the only one the 250 shipped
/// presets use (starbursts, ticket notches, chevron rails), and it is the one
/// form that maps exactly onto a `Path` — `inset()`, `circle()` and `path()`
/// would each need their own geometry and none of them appear in the library.
/// An optional leading fill rule (`nonzero` / `evenodd`) is accepted and
/// ignored: both rules draw these convex-ish outlines the same way.
public func revnixParsePolygon(_ css: String?) -> [RevnixPolygonPoint]? {
    guard let css else { return nil }
    let trimmed = css.trimmingCharacters(in: .whitespaces)
    guard trimmed.lowercased().hasPrefix("polygon("), trimmed.hasSuffix(")") else { return nil }
    let inner = String(trimmed.dropFirst("polygon(".count).dropLast())

    var groups = revnixSplitTopLevel(inner, on: ",")
    if let first = groups.first {
        let rule = first.lowercased()
        if rule == "nonzero" || rule == "evenodd" { groups.removeFirst() }
    }
    // Two points describe a line, which clips a block away to nothing. Better
    // to decline and leave the block visible than to erase it.
    guard groups.count >= 3 else { return nil }

    var points: [RevnixPolygonPoint] = []
    points.reserveCapacity(groups.count)
    for group in groups {
        let axes = revnixSplitTopLevel(group, on: " ")
        guard axes.count == 2,
              let x = revnixParseLength(axes[0]),
              let y = revnixParseLength(axes[1])
        else { return nil }
        points.append(RevnixPolygonPoint(x: x, y: y))
    }
    return points
}

// MARK: - background-size

/// A parsed `fillSize`. `cover`/`contain` are carried for completeness; the
/// case that changes what ships is `.tile`, because a repeating-gradient wash
/// with no tile size stretches into a single band.
public enum RevnixFillSize: Sendable, Equatable {
    case cover
    case contain
    case tile(width: RevnixLength, height: RevnixLength)
}

/// `"18px 18px"` / `"32px 16px"` / `"cover"`. A single length sets the width
/// and leaves the height automatic, which CSS renders as a square tile for the
/// gradient washes this is used for.
public func revnixParseFillSize(_ css: String?) -> RevnixFillSize? {
    guard let css else { return nil }
    let trimmed = css.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.isEmpty { return nil }
    if trimmed == "cover" { return .cover }
    if trimmed == "contain" { return .contain }
    let parts = revnixSplitTopLevel(trimmed, on: " ")
    guard let first = parts.first, let w = revnixParseLength(first) else { return nil }
    let h = parts.count > 1 ? revnixParseLength(parts[1]) : w
    guard let h else { return nil }
    // A zero or negative tile would divide by zero when laying the tiles out.
    guard w.fraction > 0 || w.points > 0, h.fraction > 0 || h.points > 0 else { return nil }
    return .tile(width: w, height: h)
}

#if canImport(SwiftUI)

// MARK: - SwiftUI adapters

/// The parsed polygon as a clip shape. Percentages resolve against the rect
/// the block was actually given, so the same document clips identically at
/// any width — which is what makes this match the dashboard preview.
struct RevnixPolygonShape: Shape {
    let points: [RevnixPolygonPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 3 else { return path }
        for (i, p) in points.enumerated() {
            let point = CGPoint(
                x: rect.minX + p.x.resolved(against: rect.width),
                y: rect.minY + p.y.resolved(against: rect.height)
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Reports a measured size up the view tree. Only used for the percentage
/// translate case, so a design that translates by points pays nothing.
private struct RevnixSizeKey: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Applies a CSS `translate` — including one written as a percentage of the
/// block's own size, which needs the block measured first.
///
/// The measurement rides in a `.background`, so it reads the laid-out size
/// without taking part in layout itself; offsetting afterwards moves the block
/// without moving its slot, exactly as CSS `translate` does.
struct RevnixTranslateModifier: ViewModifier {
    let translate: RevnixTranslate?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        guard let translate else { return AnyView(content) }
        // Points-only: no measuring, no state, no extra pass.
        if translate.isAbsolute {
            return AnyView(content.offset(x: translate.x.points, y: translate.y.points))
        }
        return AnyView(
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: RevnixSizeKey.self, value: proxy.size)
                    }
                )
                .onPreferenceChange(RevnixSizeKey.self) { size = $0 }
                .offset(
                    x: translate.x.resolved(against: size.width),
                    y: translate.y.resolved(against: size.height)
                )
        )
    }
}

#endif
