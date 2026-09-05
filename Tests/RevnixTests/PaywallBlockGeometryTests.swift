// The geometry style fields — `clipPath`, `translate`, `fillSize`, `textWrap`.
//
// All four were named by revnix-app's BlockStyle and by NONE of the native
// renderers, so `init(from:)` dropped them on the floor. 13 of the 25 shipped
// template categories set at least one. The two that change where pixels land
// are pinned here end to end: a polygon must clip, and a percentage translate
// must resolve against the block's OWN size (the whole point of the badge
// centring idiom `left: 50%` + `translate: "-50% 0"`).
//
// The other two are pinned as CARRIED: they must survive decoding and merging
// even though this platform cannot render them, because a field that decodes
// is a documented limitation while a field that does not is a silent one.

import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import Revnix

final class PaywallBlockGeometryTests: XCTestCase {

    // MARK: - Lengths

    func testLengthReadsEveryFormTheDesignsWrite() throws {
        XCTAssertEqual(revnixParseLength("16px"), RevnixLength(fraction: 0, points: 16))
        XCTAssertEqual(revnixParseLength("-8px"), RevnixLength(fraction: 0, points: -8))
        // A bare number is points — how the designs write a zero.
        XCTAssertEqual(revnixParseLength("0"), RevnixLength(fraction: 0, points: 0))
        XCTAssertEqual(revnixParseLength("50%"), RevnixLength(fraction: 0.5, points: 0))
        XCTAssertEqual(revnixParseLength("-50%"), RevnixLength(fraction: -0.5, points: 0))
        XCTAssertEqual(revnixParseLength(" 100% "), RevnixLength(fraction: 1, points: 0))
    }

    func testCalcCarriesBothHalves() throws {
        // The ticket-notch clips are authored as calc(100% - 16px); reading
        // only one half of that puts the notch at the wrong edge.
        XCTAssertEqual(revnixParseLength("calc(100% - 16px)"),
                       RevnixLength(fraction: 1, points: -16))
        XCTAssertEqual(revnixParseLength("calc(50% + 4px)"),
                       RevnixLength(fraction: 0.5, points: 4))
    }

    func testUnreadableLengthIsDeclinedRatherThanGuessed() throws {
        XCTAssertNil(revnixParseLength("var(--x)"))
        XCTAssertNil(revnixParseLength("4rem"))
        XCTAssertNil(revnixParseLength(""))
    }

    func testLengthResolvesAsMultiplyAdd() throws {
        let notch = try XCTUnwrap(revnixParseLength("calc(100% - 16px)"))
        XCTAssertEqual(notch.resolved(against: 200), 184)
        XCTAssertFalse(notch.isAbsolute)
        XCTAssertTrue(try XCTUnwrap(revnixParseLength("12px")).isAbsolute)
    }

    // MARK: - translate

    func testTranslateReadsTheBadgeCentringIdiom() throws {
        let t = try XCTUnwrap(revnixParseTranslate("-50% 0"))
        XCTAssertEqual(t.x, RevnixLength(fraction: -0.5, points: 0))
        XCTAssertEqual(t.y, RevnixLength())
        XCTAssertFalse(t.isAbsolute)
        // The badge is pulled back by half its OWN width, not the parent's.
        XCTAssertEqual(t.x.resolved(against: 120), -60)
    }

    func testTranslateReadsThePointsForm() throws {
        let t = try XCTUnwrap(revnixParseTranslate("0 -8px"))
        XCTAssertEqual(t.y.points, -8)
        // Points-only skips the measuring pass entirely.
        XCTAssertTrue(t.isAbsolute)
    }

    func testSingleComponentTranslateLeavesYAtZero() throws {
        let t = try XCTUnwrap(revnixParseTranslate("12px"))
        XCTAssertEqual(t.x.points, 12)
        XCTAssertEqual(t.y, RevnixLength())
    }

    func testUnreadableTranslateMovesNothing() throws {
        XCTAssertNil(revnixParseTranslate("nonsense"))
        XCTAssertNil(revnixParseTranslate(""))
        XCTAssertNil(revnixParseTranslate(nil))
    }

    // MARK: - clip-path

    func testPolygonReadsATriangle() throws {
        let points = try XCTUnwrap(revnixParsePolygon("polygon(50% 0,100% 100%,0 100%)"))
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].x, RevnixLength(fraction: 0.5, points: 0))
        XCTAssertEqual(points[1].y, RevnixLength(fraction: 1, points: 0))
    }

    func testPolygonKeepsCalcPointsTogether() throws {
        // The space inside calc() must NOT split the point in two — this is
        // the ticket notch, and splitting naively yields garbage vertices.
        let css = "polygon(0 0,100% 0,100% calc(100% - 16px),50% 100%,0 calc(100% - 16px))"
        let points = try XCTUnwrap(revnixParsePolygon(css))
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points[2].y, RevnixLength(fraction: 1, points: -16))
        XCTAssertEqual(points[4].y, RevnixLength(fraction: 1, points: -16))
    }

    func testPolygonReadsThe32PointStarburst() throws {
        // The library's busiest clip; it must not be truncated or refused.
        let css = "polygon(50% 0%,57% 9%,68% 4%,72% 15%,84% 13%,84% 25%,96% 27%,"
            + "92% 38%,100% 45%,93% 54%,98% 65%,88% 69%,89% 81%,77% 80%,73% 92%,"
            + "62% 87%,54% 97%,46% 88%,35% 94%,30% 83%,18% 84%,20% 72%,8% 68%,"
            + "14% 58%,5% 50%,13% 42%,7% 31%,18% 28%,17% 16%,29% 17%,32% 5%,43% 9%)"
        let points = try XCTUnwrap(revnixParsePolygon(css))
        XCTAssertEqual(points.count, 32)
    }

    func testLeadingFillRuleIsAcceptedAndIgnored() throws {
        let points = try XCTUnwrap(revnixParsePolygon("polygon(evenodd, 0 0, 100% 0, 50% 100%)"))
        XCTAssertEqual(points.count, 3)
    }

    func testNonPolygonClipIsDeclined() throws {
        // Declining leaves the block its full rectangle. The alternative —
        // guessing — can clip a block away to nothing, which loses copy.
        XCTAssertNil(revnixParsePolygon("inset(10px)"))
        XCTAssertNil(revnixParsePolygon("circle(50%)"))
        XCTAssertNil(revnixParsePolygon("url(#mask)"))
        XCTAssertNil(revnixParsePolygon(nil))
    }

    func testDegeneratePolygonIsDeclined() throws {
        // Two points describe a line, which would erase the block.
        XCTAssertNil(revnixParsePolygon("polygon(0 0,100% 100%)"))
        // A point missing an axis makes the whole path untrustworthy.
        XCTAssertNil(revnixParsePolygon("polygon(0 0,100% 0,50%)"))
    }

    #if canImport(SwiftUI)
    func testPolygonShapeResolvesAgainstTheBoxItIsGiven() throws {
        let points = try XCTUnwrap(revnixParsePolygon("polygon(50% 0,100% 100%,0 100%)"))
        let path = RevnixPolygonShape(points: points)
            .path(in: CGRect(x: 0, y: 0, width: 200, height: 100))
        // Apex centred, base on the bottom edge — the same triangle at any
        // width, which is what keeps device and dashboard in agreement.
        XCTAssertEqual(path.boundingRect.width, 200, accuracy: 0.01)
        XCTAssertEqual(path.boundingRect.height, 100, accuracy: 0.01)
        XCTAssertFalse(path.isEmpty)
    }

    func testPolygonShapeHonoursANonZeroOrigin() throws {
        let points = try XCTUnwrap(revnixParsePolygon("polygon(0 0,100% 0,100% 100%)"))
        let path = RevnixPolygonShape(points: points)
            .path(in: CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(path.boundingRect.minX, 10, accuracy: 0.01)
        XCTAssertEqual(path.boundingRect.minY, 20, accuracy: 0.01)
    }
    #endif

    // MARK: - fillSize

    func testFillSizeReadsTheTileForms() throws {
        XCTAssertEqual(revnixParseFillSize("18px 18px"),
                       .tile(width: RevnixLength(points: 18), height: RevnixLength(points: 18)))
        XCTAssertEqual(revnixParseFillSize("32px 16px"),
                       .tile(width: RevnixLength(points: 32), height: RevnixLength(points: 16)))
        // One length squares the tile, as CSS does for these washes.
        XCTAssertEqual(revnixParseFillSize("6px"),
                       .tile(width: RevnixLength(points: 6), height: RevnixLength(points: 6)))
        XCTAssertEqual(revnixParseFillSize("cover"), .cover)
        XCTAssertEqual(revnixParseFillSize("contain"), .contain)
    }

    func testDegenerateFillSizeIsDeclined() throws {
        // A zero tile would divide by zero when laying tiles out.
        XCTAssertNil(revnixParseFillSize("0 0"))
        XCTAssertNil(revnixParseFillSize(""))
        XCTAssertNil(revnixParseFillSize(nil))
    }

    // MARK: - The model carries all four

    private func style(_ json: String) throws -> BlockStyle {
        try JSONDecoder().decode(BlockStyle.self, from: Data(json.utf8))
    }

    func testAllFourFieldsSurviveDecoding() throws {
        let s = try style("""
            {"clipPath":"polygon(50% 0,100% 100%,0 100%)","translate":"-50% 0",
             "fillSize":"18px 18px","textWrap":"pretty"}
            """)
        XCTAssertEqual(s.clipPath, "polygon(50% 0,100% 100%,0 100%)")
        XCTAssertEqual(s.translate, "-50% 0")
        XCTAssertEqual(s.fillSize, "18px 18px")
        XCTAssertEqual(s.textWrap, "pretty")
    }

    func testAllFourFieldsMergeLikeSelectedStyle() throws {
        // A plan card's selectedStyle merges over its base style. A field the
        // merge forgets is a field that cannot be changed on selection.
        let base = try style("""
            {"clipPath":"polygon(0 0,100% 0,50% 100%)","translate":"0 0",
             "fillSize":"6px 6px","textWrap":"pretty"}
            """)
        let selected = try style("""
            {"clipPath":"polygon(0 0,100% 0,100% 100%)","translate":"-50% 0",
             "fillSize":"18px 18px","textWrap":"balance"}
            """)
        let merged = base.merging(selected)
        XCTAssertEqual(merged.clipPath, "polygon(0 0,100% 0,100% 100%)")
        XCTAssertEqual(merged.translate, "-50% 0")
        XCTAssertEqual(merged.fillSize, "18px 18px")
        XCTAssertEqual(merged.textWrap, "balance")
    }

    func testMergeLeavesUnsetGeometryAlone() throws {
        let base = try style("""
            {"clipPath":"polygon(0 0,100% 0,50% 100%)","translate":"-50% 0",
             "fillSize":"6px 6px","textWrap":"pretty"}
            """)
        let merged = base.merging(try style("{\"fill\":\"#fff\"}"))
        XCTAssertEqual(merged.clipPath, "polygon(0 0,100% 0,50% 100%)")
        XCTAssertEqual(merged.translate, "-50% 0")
        XCTAssertEqual(merged.fillSize, "6px 6px")
        XCTAssertEqual(merged.textWrap, "pretty")
    }

    func testAnUnreadableGeometryValueCostsOnlyItself() throws {
        // Decoding stays total: a style whose translate is the wrong TYPE
        // keeps every other field rather than failing the block.
        let s = try style("{\"translate\":42,\"fill\":\"#101014\",\"clipPath\":\"polygon(0 0,100% 0,50% 100%)\"}")
        XCTAssertNil(s.translate)
        XCTAssertEqual(s.fill, "#101014")
        XCTAssertEqual(s.clipPath, "polygon(0 0,100% 0,50% 100%)")
    }
}
