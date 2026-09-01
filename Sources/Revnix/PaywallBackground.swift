// The paywall screen background — the Swift half of the dashboard's model.
//
// A background is either the original CSS string (a colour or a gradient) or a
// layered spec: a ground colour/gradient, then a photo (fit, focal point,
// opacity, blur), then a scrim. `backgroundLayers` resolves either form to one
// paint list, mirroring revnix-app/src/lib/paywall-blocks/background.ts and the
// React SDK's blocks/background.ts — the same names, the same defaults, the
// same clamping.
//
// Two things this file exists to get right:
//
//  1. The ground field on the wire is `color`. It is NOT `ground` — that is the
//     name of the RESOLVED layer, and decoding it off the wire is what rendered
//     every edited paywall pure black. `ground` stays accepted so a document
//     published by a build that wrote it still opens.
//
//  2. Most shipped library backgrounds are CSS gradients, which the colour
//     parser rejects by design. They are parsed here into descriptors the view
//     layer turns into SwiftUI gradients, so the ground paints as designed
//     rather than falling back to black.

import Foundation

/// How a background photo fills the screen.
public enum RevnixBackgroundFit: String, Sendable, Equatable {
    case cover
    case contain
}

/// The photo layer.
public struct RevnixBackgroundImage: Sendable, Equatable {
    /// An https URL the device can load.
    public var url: String
    public var fit: RevnixBackgroundFit
    /// Focal point in percent (0-100, 50/50 = centred): the part of the photo
    /// that must survive a cover-crop.
    public var focalX: Double
    public var focalY: Double
    /// 0-1.
    public var opacity: Double
    /// Blur radius in px; nil when no blur was asked for.
    public var blur: Double?
}

/// The scrim painted over the photo.
public struct RevnixBackgroundOverlay: Sendable, Equatable {
    /// Any colour or gradient string.
    public var fill: String
    /// 0-1.
    public var opacity: Double
}

/// The resolved paint list, bottom layer first.
public struct RevnixBackgroundLayers: Sendable, Equatable {
    /// The ground fill (a colour or gradient string), or nil for none.
    public var ground: String?
    public var image: RevnixBackgroundImage?
    public var overlay: RevnixBackgroundOverlay?

    /// True when the background paints nothing but a ground — the shape every
    /// unedited paywall has, and the one that needs no extra layers at all.
    public var isGroundOnly: Bool { image == nil && overlay == nil }
}

/// 0-100 (or absent) -> 0-1, clamped.
private func revnixPct(_ value: Double?, _ fallback: Double) -> Double {
    guard let value, value.isFinite else { return fallback }
    return min(1, max(0, value / 100))
}

/// 0-100 (or absent) -> a clamped percentage.
private func revnixCoord(_ value: Double?) -> Double {
    guard let value, value.isFinite else { return 50 }
    return min(100, max(0, value))
}

public extension RevnixJSONValue {
    /// The string behind a value, or nil for any other kind.
    var revnixString: String? {
        if case let .string(s) = self { return s.isEmpty ? nil : s }
        return nil
    }

    /// The number behind a value, or nil for any other kind.
    var revnixNumber: Double? {
        if case let .number(n) = self { return n }
        return nil
    }

    /// The object behind a value, or nil for any other kind.
    var revnixObject: [String: RevnixJSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }
}

/// The ground paint of a background: `color`, or the legacy `ground`.
///
/// Reading `color` FIRST is the fix: it is the only key the dashboard writes.
public func revnixBackgroundGround(_ background: RevnixJSONValue?) -> String? {
    guard let background else { return nil }
    if let s = background.revnixString { return s }
    guard let o = background.revnixObject else { return nil }
    return o["color"]?.revnixString ?? o["ground"]?.revnixString
}

/// The paint list for a background: ground, then photo, then scrim. Layers
/// that would draw nothing (no url, zero opacity) are dropped, so a legacy
/// string resolves to exactly one ground layer.
public func revnixBackgroundLayers(
    _ background: RevnixJSONValue?,
    resolve: (String) -> String = { $0 }
) -> RevnixBackgroundLayers {
    let ground = revnixBackgroundGround(background).map(resolve)
    guard let o = background?.revnixObject else {
        return RevnixBackgroundLayers(ground: ground, image: nil, overlay: nil)
    }

    var image: RevnixBackgroundImage?
    if let i = o["image"]?.revnixObject,
       let url = i["url"]?.revnixString {
        let opacity = revnixPct(i["opacity"]?.revnixNumber, 1)
        if opacity > 0 {
            let blur = i["blur"]?.revnixNumber
            image = RevnixBackgroundImage(
                url: url,
                fit: i["fit"]?.revnixString == "contain" ? .contain : .cover,
                focalX: revnixCoord(i["focalX"]?.revnixNumber),
                focalY: revnixCoord(i["focalY"]?.revnixNumber),
                opacity: opacity,
                blur: (blur ?? 0) > 0 ? blur : nil
            )
        }
    }

    var overlay: RevnixBackgroundOverlay?
    if let v = o["overlay"]?.revnixObject, let fill = v["fill"]?.revnixString {
        let opacity = revnixPct(v["opacity"]?.revnixNumber, 1)
        if opacity > 0 {
            overlay = RevnixBackgroundOverlay(fill: resolve(fill), opacity: opacity)
        }
    }

    return RevnixBackgroundLayers(ground: ground, image: image, overlay: overlay)
}

/// The flat colour a gradient ground stands in for — what paints UNDER the
/// gradient, so a form this parser does not understand still shows a colour
/// from the design rather than black.
///
/// It reads the LAST comma-separated layer, because in CSS the first-listed
/// layer paints on TOP: taking the first colour would answer with the
/// translucent accent glow the library's Spotlight and Corner halo presets
/// stack over their base, not with the base itself. Fully transparent stops
/// are skipped for the same reason.
///
/// This is NOT what `@bg` resolves to. The dashboard answers that token with
/// the raw ground, which `color-mix()` cannot take when it is a gradient, so a
/// `@bg` tint over a gradient renders nothing in the builder — and must render
/// nothing here too, or the device stops matching the design.
public func revnixBackgroundBaseColor(_ ground: String?) -> String {
    let s = ground?.trimmingCharacters(in: .whitespaces) ?? ""
    if s.isEmpty { return "#000000" }
    let bottom = revnixSplitTopLevel(s).last ?? s
    var colors: [String] = []
    var search = bottom.startIndex ..< bottom.endIndex
    while let match = bottom.range(
        of: "#[0-9a-fA-F]{3,8}|rgba?\\([^)]*\\)",
        options: [.regularExpression, .caseInsensitive],
        range: search
    ) {
        colors.append(String(bottom[match]))
        search = match.upperBound ..< bottom.endIndex
    }
    if colors.isEmpty { return s }
    return colors.first(where: { !revnixIsFullyTransparent($0) }) ?? colors[0]
}

/// Whether a colour literal is fully transparent. Kept here rather than routed
/// through the block colour parser, which lives behind `canImport(SwiftUI)` —
/// only the two forms the dashboard emits are recognised, and anything else
/// counts as opaque, which is the safe answer for picking a ground.
func revnixIsFullyTransparent(_ color: String) -> Bool {
    let s = color.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") {
        let hex = String(s.dropFirst())
        if hex.count == 8 { return UInt8(hex.suffix(2), radix: 16) == 0 }
        if hex.count == 4 { return UInt8(String(hex.suffix(1)), radix: 16) == 0 }
        return false
    }
    guard let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")") else { return false }
    let parts = s[s.index(after: open) ..< close]
        .split(whereSeparator: { ", /".contains($0) })
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count >= 4 else { return false }
    return Double(parts[3]) == 0
}

// MARK: - CSS gradients

/// One colour stop: the colour string and its position in 0-1.
public struct RevnixGradientStop: Sendable, Equatable {
    public var color: String
    public var position: Double
}

/// A parsed CSS gradient, in terms the view layer turns into a SwiftUI
/// gradient.
public enum RevnixGradient: Sendable, Equatable {
    /// `dirX`/`dirY` is the unit direction in screen coordinates (x right,
    /// y down), scaled so its largest component is 1 — which is what makes
    /// 135deg run corner to corner as CSS draws it.
    case linear(dirX: Double, dirY: Double, stops: [RevnixGradientStop])
    /// `centerX`/`centerY` are 0-1 fractions of the box and `radius` is a
    /// fraction of the box's LARGER side. CSS gives an ellipse with
    /// independent extents; taking the larger keeps a glow from stopping short
    /// of the edge it was drawn to reach. The circular shape is a deliberate
    /// approximation.
    case radial(centerX: Double, centerY: Double, radius: Double, stops: [RevnixGradientStop])

    public var stops: [RevnixGradientStop] {
        switch self {
        case let .linear(_, _, stops): return stops
        case let .radial(_, _, _, stops): return stops
        }
    }
}

/// Splits on top-level commas only, so the commas inside `rgba(...)` and
/// inside a nested gradient's argument list do not tear an argument in half.
func revnixSplitTopLevel(_ input: String) -> [String] {
    var out: [String] = []
    var depth = 0
    var current = ""
    for c in input {
        if c == "(" { depth += 1 }
        if c == ")" && depth > 0 { depth -= 1 }
        if c == "," && depth == 0 {
            out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
        } else {
            current.append(c)
        }
    }
    let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { out.append(tail) }
    return out
}

private struct RawStop {
    var color: String
    var position: Double?
}

private func revnixParseStop(_ raw: String, isColor: (String) -> Bool) -> RawStop? {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if s.isEmpty { return nil }
    // The position is the trailing `<n>%`; everything before it is the colour,
    // which may itself contain spaces (`rgba(0, 0, 0, 0.5)`).
    if let match = s.range(of: "\\s+-?[0-9.]+%\\s*$", options: .regularExpression) {
        let color = String(s[s.startIndex ..< match.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard isColor(color) else { return nil }
        let pctText = String(s[match])
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "")
        let pct = Double(pctText).map { min(1, max(0, $0 / 100)) }
        return RawStop(color: color, position: pct)
    }
    guard isColor(s) else { return nil }
    return RawStop(color: s, position: nil)
}

/// Fills in the positions CSS would interpolate for stops that gave none.
private func revnixStopPositions(_ stops: [RawStop]) -> [Double] {
    var out = stops.map { $0.position }
    if out.first! == nil { out[0] = 0 }
    if out.last! == nil { out[out.count - 1] = 1 }
    var i = 1
    while i < out.count - 1 {
        if out[i] != nil { i += 1; continue }
        var next = i + 1
        while next < out.count && out[next] == nil { next += 1 }
        let from = out[i - 1]!
        let to = out[next]!
        let span = Double(next - (i - 1))
        for k in i ..< next {
            out[k] = from + (to - from) * (Double(k - (i - 1)) / span)
        }
        i = next
    }
    // Gradient stops must be non-decreasing.
    var previous = 0.0
    return out.map { value in
        let v = min(1, max(0, value ?? previous))
        let result = v < previous ? previous : v
        previous = result
        return result
    }
}

/// Parses the gradient forms the dashboard emits — `linear-gradient(Ndeg, ...)`
/// and `radial-gradient(RX% RY% at X% Y%, ...)` — plus the comma-separated
/// stacks of them the library's Spotlight and Corner halo presets use.
///
/// Returns the layers BOTTOM FIRST, the reverse of CSS's own order (in CSS the
/// first-listed layer paints on top), so the result can be dropped straight
/// into a ZStack.
public func revnixParseCssGradients(
    _ css: String,
    isColor: (String) -> Bool
) -> [RevnixGradient] {
    revnixSplitTopLevel(css).compactMap { revnixParseOneGradient($0, isColor: isColor) }.reversed()
}

private func revnixParseOneGradient(_ raw: String, isColor: (String) -> Bool) -> RevnixGradient? {
    let s = raw.trimmingCharacters(in: .whitespaces)
    guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
    let name = String(s[s.startIndex ..< open]).trimmingCharacters(in: .whitespaces).lowercased()
    let inner = String(s[s.index(after: open) ..< s.index(before: s.endIndex)])
    let args = revnixSplitTopLevel(inner)
    guard !args.isEmpty else { return nil }

    if name == "linear-gradient" {
        var angle = 180.0
        var first = 0
        let head = args[0].trimmingCharacters(in: .whitespaces).lowercased()
        if head.hasSuffix("deg"), let value = Double(head.dropLast(3)) {
            angle = value
            first = 1
        } else if head.hasPrefix("to ") {
            angle = revnixAngleForKeyword(String(head.dropFirst(3))) ?? 180
            first = 1
        }
        let stops = args.dropFirst(first).compactMap { revnixParseStop($0, isColor: isColor) }
        guard stops.count >= 2 else { return nil }
        // CSS measures clockwise from "to top", so the gradient runs along
        // (sin a, -cos a) in screen coordinates.
        let radians = angle * Double.pi / 180
        var dx = sin(radians)
        var dy = -cos(radians)
        let longest = max(abs(dx), abs(dy))
        if longest > 0.0001 { dx /= longest; dy /= longest }
        // sin(pi) is 1.2e-16, not 0, so an axis-aligned gradient carries a hair
        // of the other axis. Harmless on screen, but snapping it keeps the
        // descriptor exact and comparable.
        if abs(dx) < 1e-9 { dx = 0 }
        if abs(dy) < 1e-9 { dy = 0 }
        let positions = revnixStopPositions(stops)
        return .linear(
            dirX: dx,
            dirY: dy,
            stops: stops.enumerated().map {
                RevnixGradientStop(color: $0.element.color, position: positions[$0.offset])
            }
        )
    }

    if name == "radial-gradient" {
        var centerX = 0.5
        var centerY = 0.5
        var radius = 0.5
        var first = 0
        let head = args[0].trimmingCharacters(in: .whitespaces)
        let numbers = revnixPercents(in: head)
        if head.range(of: "^[0-9.]+%\\s+[0-9.]+%", options: .regularExpression) != nil,
           numbers.count >= 2 {
            radius = min(4, max(0.05, max(numbers[0], numbers[1]) / 100))
            if numbers.count >= 4 {
                centerX = numbers[2] / 100
                centerY = numbers[3] / 100
            }
            first = 1
        } else if head.lowercased().hasPrefix("at "), numbers.count >= 2 {
            centerX = numbers[0] / 100
            centerY = numbers[1] / 100
            first = 1
        }
        let stops = args.dropFirst(first).compactMap { revnixParseStop($0, isColor: isColor) }
        guard stops.count >= 2 else { return nil }
        let positions = revnixStopPositions(stops)
        return .radial(
            centerX: centerX,
            centerY: centerY,
            radius: radius,
            stops: stops.enumerated().map {
                RevnixGradientStop(color: $0.element.color, position: positions[$0.offset])
            }
        )
    }

    return nil
}

/// Every `<n>%` in a string, in order.
private func revnixPercents(in text: String) -> [Double] {
    var out: [Double] = []
    var search = text.startIndex ..< text.endIndex
    while let match = text.range(of: "[0-9.]+%", options: .regularExpression, range: search) {
        if let value = Double(text[match].dropLast()) { out.append(value) }
        search = match.upperBound ..< text.endIndex
    }
    return out
}

private func revnixAngleForKeyword(_ keyword: String) -> Double? {
    let normalised = keyword
        .trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    switch normalised {
    case "top": return 0
    case "right": return 90
    case "bottom": return 180
    case "left": return 270
    case "top right", "right top": return 45
    case "bottom right", "right bottom": return 135
    case "bottom left", "left bottom": return 225
    case "top left", "left top": return 315
    default: return nil
    }
}

/// Cover-fit geometry with a focal point — the stand-in for CSS
/// `object-position`, which SwiftUI's image modifiers have no equivalent of.
///
/// Given the box and the source dimensions it returns the drawn size and the
/// offset that puts the focal point as close to the box's matching anchor as
/// the image edges allow: exactly CSS's `object-position: X% Y%` rule, where
/// the X% point of the image aligns to the X% point of the box, clamped so no
/// edge shows. Ported from the React SDK's `coverPlacement` so the two agree
/// pixel for pixel.
public func revnixCoverPlacement(
    box: (width: Double, height: Double),
    source: (width: Double, height: Double),
    focalX: Double,
    focalY: Double
) -> (width: Double, height: Double, left: Double, top: Double) {
    guard box.width > 0, box.height > 0, source.width > 0, source.height > 0 else {
        return (box.width, box.height, 0, 0)
    }
    let scale = max(box.width / source.width, box.height / source.height)
    let width = source.width * scale
    let height = source.height * scale
    func place(_ boxLen: Double, _ drawnLen: Double, _ pctPoint: Double) -> Double {
        let offset = (boxLen - drawnLen) * (pctPoint / 100)
        // Clamp: never pull an image edge inside the box.
        let clamped = min(0, max(boxLen - drawnLen, offset))
        return clamped == 0 ? 0 : clamped
    }
    return (
        width,
        height,
        place(box.width, width, focalX),
        place(box.height, height, focalY)
    )
}
