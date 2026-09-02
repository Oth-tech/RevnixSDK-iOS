// Block fills: the half of a paint string that is NOT a plain colour.
//
// A `fill` is handed straight to CSS `background` by the dashboard, so it may
// be a colour, a gradient, or a stack of them. This SDK parsed only the first
// form and painted nothing for the others — 113 of the 250 shipped gallery
// presets use a gradient somewhere, so "nothing" was the common case.
//
// Three separate defects are pinned here, because each of them alone was
// enough to lose a gradient:
//
//   1. the fill was never routed through the gradient parser at all;
//   2. `@bg` resolved to the RAW ground, so a `@bg` stop inside a gradient
//      failed to parse and was dropped — and a gradient left with one stop
//      does not parse either, taking the whole fill with it;
//   3. a stop may carry TWO positions (`@accent 0 22%`), and reading only the
//      last one turned every hard edge in the library into a smooth fade.

import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import Revnix

final class PaywallBlockFillTests: XCTestCase {

    private func doc(background: String = "#101014") throws -> PaywallBlockDoc {
        let json = """
            {"version":1,"background":"\(background)","textColor":"#F5F7FA",
             "accent":"#6478ff","accentInk":"#0B0D10",
             "blocks":[{"id":"t","type":"text","text":"Hello"}]}
            """
        return try JSONDecoder().decode(PaywallBlockDoc.self, from: Data(json.utf8))
    }

    private func parse(_ css: String, _ doc: PaywallBlockDoc) -> [RevnixGradient] {
        revnixParseCssGradients(css, isColor: { revnixBlockColor($0, doc) != nil })
    }

    // MARK: - Resolving a fill

    func testAPlainColourFillStaysAPlainColour() throws {
        let doc = try doc()
        guard case let .color(colour)? = revnixBlockFill("#FF0000", doc) else {
            return XCTFail("expected a flat colour")
        }
        XCTAssertEqual(colour, Color(revnixBlockHex: "#FF0000"))
    }

    func testAnAbsentFillPaintsNothing() throws {
        let doc = try doc()
        XCTAssertNil(revnixBlockFill(nil, doc))
        XCTAssertNil(revnixBlockFill("   ", doc))
    }

    func testAGradientFillResolvesToItsLayersAndNothingUnderThem() throws {
        let doc = try doc()
        guard case let .gradients(layers)? =
            revnixBlockFill("linear-gradient(135deg, #112233 0%, #445566 100%)", doc)
        else { return XCTFail("expected gradient layers") }
        XCTAssertEqual(layers.count, 1)
    }

    func testATranslucentScrimIsNotBackedByAnOpaqueBox() throws {
        // 83 of the library's 139 gradient fills fade through a translucent
        // stop: they are drawn OVER the screen's photo so it shows through.
        // A flat base under them would make every one of those a solid block.
        let doc = try doc()
        guard case let .gradients(layers)? = revnixBlockFill(
            "linear-gradient(180deg, rgba(15,16,19,0.72) 0%, rgba(15,16,19,0.1) 32%, #0F1013 100%)",
            doc
        ) else { return XCTFail("expected gradient layers") }
        XCTAssertEqual(layers.count, 1)
        // The flat colour is the FALLBACK case's business, not this one — the
        // enum has nowhere to put it precisely so it cannot leak back in.
        XCTAssertEqual(layers[0].stops.count, 3)
    }

    func testAStackedGradientKeepsEveryLayerBottomFirst() throws {
        let doc = try doc()
        let css = "radial-gradient(120% 90% at 86% 4%, #FF3D7F 0%, rgba(255,61,127,0) 48%),"
            + "linear-gradient(180deg, #1C1046 0%, #0E0722 100%)"
        guard case let .gradients(layers)? = revnixBlockFill(css, doc) else {
            return XCTFail("expected gradient layers")
        }
        XCTAssertEqual(layers.count, 2)
        // CSS paints the FIRST-listed layer on top, so the list is reversed:
        // the linear base must come first, ready for a ZStack.
        guard case .linear = layers[0] else { return XCTFail("bottom layer should be the linear") }
        guard case .radial = layers[1] else { return XCTFail("top layer should be the radial") }
    }

    func testTheFlatBaseIsStillWhatAColourOnlyFieldCollapsesTo() throws {
        // The base colour did not go away — it moved to the only place it is
        // correct: a field that can hold one colour, and the parse-failure
        // fallback. Both read the BOTTOM layer's first opaque stop.
        let doc = try doc()
        let css = "radial-gradient(120% 90% at 86% 4%, #FF3D7F 0%, rgba(255,61,127,0) 48%),"
            + "linear-gradient(180deg, #1C1046 0%, #0E0722 100%)"
        XCTAssertEqual(revnixBlockStrokeColor(css, doc), Color(revnixBlockHex: "#1C1046"))
    }

    func testAUnitlessPositionIsReadRatherThanSwallowingTheStop() throws {
        // CSS allows a unitless zero. The old parser required a `%`, so the
        // whole "#112233 0" argument was taken as the COLOUR, failed to parse,
        // and the stop was dropped — and a gradient left with one stop does not
        // parse at all, so the fill was lost outright.
        let doc = try doc()
        let layers = parse("linear-gradient(180deg, #112233 0, #445566 100%)", doc)
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0].stops.count, 2)
        XCTAssertEqual(layers[0].stops[0].color, "#112233")
        XCTAssertEqual(layers[0].stops[0].position, 0, accuracy: 0.0001)
    }

    func testAMalformedPositionCostsThePositionNotTheStop() throws {
        // The token comes off the colour either way. Leaving it attached would
        // make the colour unparseable and drop the stop with it.
        let doc = try doc()
        let layers = parse("linear-gradient(180deg, #112233 1.2.3%, #445566 100%)", doc)
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0].stops.count, 2)
    }

    func testARepeatingPatternPaintsNothingRatherThanAStripeColour() throws {
        // The colours inside a pattern are STRIPE colours. The library's
        // hairline grid is `#0E1B21` once every 26px; as a solid fill it is a
        // slab, which is a wrong answer rather than a degraded one.
        let doc = try doc()
        var reported: [String] = []
        XCTAssertNil(revnixBlockFill(
            "repeating-linear-gradient(180deg, #0E1B21 0 1px, @bg 1px 26px)",
            doc,
            onDiagnostic: { reported.append($0) }
        ))
        XCTAssertEqual(reported.count, 1)
    }

    func testAPatternStackedOverAGroundStillFallsBackToThatGround() throws {
        // The BOTTOM layer decides: here it is a plain colour, and a plain
        // colour is exactly the surface colour the box should take.
        let doc = try doc()
        guard case let .color(colour)? = revnixBlockFill(
            "repeating-linear-gradient(180deg, transparent 0 33px, #E2D2B6 33px 34px), #FBF3E4",
            doc
        ) else { return XCTFail("expected a fallback colour") }
        XCTAssertEqual(colour, Color(revnixBlockHex: "#FBF3E4"))
    }

    func testATokenStopWithZeroAlphaIsNotChosenAsTheBase() throws {
        // `@accent/0` is transparent, but only once resolved — judging the
        // source text alone called it opaque and answered a border with an
        // invisible colour.
        let doc = try doc()
        XCTAssertEqual(
            revnixBlockStrokeColor(
                "linear-gradient(180deg, @accent/0 0%, @accent/22 50%, @accent/0 100%)", doc
            ),
            revnixBlockColor("@accent/22", doc)
        )
    }

    func testACloseButtonKeepsAFillTheDesignGaveIt() throws {
        // The dashboard hands every button's `fill` to CSS `background`; the
        // close-button rule only decides what happens when there is NO fill.
        let doc = try doc()
        guard case let .color(colour)? = revnixBlockFill("#FF0000", doc) else {
            return XCTFail("expected the design's own colour")
        }
        XCTAssertEqual(colour, Color(revnixBlockHex: "#FF0000"))
    }

    func testAnUnreadableFillFallsBackToADesignColourAndReports() throws {
        let doc = try doc()
        var reported: [String] = []
        // A repeating gradient this build does not know. The design's own
        // colour is still in the string, and that is what must paint.
        let fill = revnixBlockFill(
            "repeating-linear-gradient(180deg, transparent 0 33px, #E2D2B6 33px 34px), #FBF3E4",
            doc,
            onDiagnostic: { reported.append($0) }
        )
        guard case let .color(colour)? = fill else { return XCTFail("expected a fallback colour") }
        XCTAssertEqual(colour, Color(revnixBlockHex: "#FBF3E4"))
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported[0].contains("unreadable fill"))
    }

    func testABlackScreenIsNeverTheFallback() throws {
        let doc = try doc()
        // The regression this whole ticket exists for: an unreadable fill used
        // to leave the box unpainted over a #000000 screen.
        guard case let .color(colour)? = revnixBlockFill(
            "conic-gradient(#123456, #654321)", doc
        ) else { return XCTFail("expected a fallback colour") }
        XCTAssertEqual(colour, Color(revnixBlockHex: "#123456"))
        XCTAssertNotEqual(colour, Color(revnixBlockHex: "#000000"))
    }

    // MARK: - Colour-only fields

    func testAGradientInAColourOnlyFieldCollapsesRatherThanDisappearing() throws {
        let doc = try doc()
        var reported: [String] = []
        let colour = revnixBlockStrokeColor(
            "linear-gradient(90deg, #00FF00 0%, #0000FF 100%)",
            doc,
            onDiagnostic: { reported.append($0) }
        )
        XCTAssertEqual(colour, Color(revnixBlockHex: "#00FF00"))
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported[0].contains("flattened"))
    }

    func testAPlainColourInAColourOnlyFieldReportsNothing() throws {
        let doc = try doc()
        var reported: [String] = []
        XCTAssertEqual(
            revnixBlockStrokeColor("@accent", doc, onDiagnostic: { reported.append($0) }),
            Color(revnixBlockHex: "#6478ff")
        )
        XCTAssertTrue(reported.isEmpty)
    }

    // MARK: - `@bg` over a gradient ground

    func testBgResolvesToTheGroundsFlatBaseNotTheRawGradient() throws {
        // The dashboard answers `@bg` with `backgroundBaseColor(...)` because
        // it feeds the token into color-mix(), which cannot take a gradient.
        let doc = try doc(background: "linear-gradient(180deg, #231646 0%, #0C0C13 100%)")
        XCTAssertEqual(revnixBlockColor("@bg", doc), Color(revnixBlockHex: "#231646"))
        // The `/pct` form has to see a colour to tint, which is the half that
        // silently produced nil while `@bg` answered with the raw gradient.
        XCTAssertNotNil(revnixBlockColor("@bg/50", doc))
    }

    func testABgStopInsideAGradientNoLongerTakesTheWholeFillWithIt() throws {
        // Before the fix `@bg` returned nil, the stop was dropped, and a
        // gradient left under two stops does not parse — so a fill the design
        // wrote as three stops painted nothing at all.
        let doc = try doc(background: "linear-gradient(180deg, #231646 0%, #0C0C13 100%)")
        let layers = parse("linear-gradient(180deg, rgba(12,16,19,0.5) 0%, @bg 100%)", doc)
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0].stops.count, 2)
    }

    // MARK: - Stop syntax the library actually ships

    func testAStopMayCarryTwoPositionsWhichIsAHardEdge() throws {
        let doc = try doc()
        // "@accent 0 22%" is the accent at BOTH 0 and 22%, then the next colour
        // starts at 22% — the progress-bar idiom, and a hard edge rather than
        // the smooth fade that reading one position produced.
        let layers = parse("linear-gradient(90deg, @accent 0 22%, #16203C 22%)", doc)
        XCTAssertEqual(layers.count, 1)
        let stops = layers[0].stops
        XCTAssertEqual(stops.count, 3)
        XCTAssertEqual(stops[0].position, 0, accuracy: 0.0001)
        XCTAssertEqual(stops[1].position, 0.22, accuracy: 0.0001)
        XCTAssertEqual(stops[2].position, 0.22, accuracy: 0.0001)
        XCTAssertEqual(stops[0].color, "@accent")
        XCTAssertEqual(stops[1].color, "@accent")
        XCTAssertEqual(stops[2].color, "#16203C")
    }

    func testTransparentIsAColourTheDesignsUse() throws {
        let doc = try doc()
        XCTAssertEqual(revnixBlockColor("transparent", doc), Color(revnixBlockHex: "#00000000"))
        let layers = parse("linear-gradient(90deg, @accent 0 60%, transparent 60%)", doc)
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0].stops.count, 3)
    }

    func testAColourWithSpacesInsideItIsNotTornApartByTheStopParser() throws {
        let doc = try doc()
        let layers = parse("linear-gradient(180deg, rgba(0, 0, 0, 0.5) 0%, #FFFFFF 100%)", doc)
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0].stops[0].color, "rgba(0, 0, 0, 0.5)")
    }
}
