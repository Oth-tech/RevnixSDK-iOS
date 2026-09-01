import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import Revnix

/// The screen background: the wire contract, the layer stack and the CSS
/// gradient parser.
///
/// `paywall-background-wire.json` is a byte-identical copy of the fixture the
/// other five renderers decode in their own suites — a real document the
/// dashboard published from its background library. It is the closest thing
/// this SDK has to a cross-repo contract test, and it exists because the six
/// renderers previously disagreed about the ground's key with nothing to catch
/// it.
final class PaywallBackgroundTests: XCTestCase {

    private let goldenGround =
        "radial-gradient(120% 85% at 50% 0%, #D6FF3F38 0%, #D6FF3F00 58%), " +
        "linear-gradient(180deg, #111820 0%, #07090C 100%)"

    private func golden() throws -> PaywallBlockDoc {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "paywall-background-wire", withExtension: "json")
        )
        return try JSONDecoder().decode(PaywallBlockDoc.self, from: Data(contentsOf: url))
    }

    private func spec(_ json: String) throws -> RevnixJSONValue {
        try JSONDecoder().decode(RevnixJSONValue.self, from: json.data(using: .utf8)!)
    }

    // MARK: - The wire contract

    func testARealPublishedDocumentResolvesToItsGradientGroundNotBlack() throws {
        XCTAssertEqual(try golden().background, goldenGround)
    }

    func testTheGroundKeyIsColor() throws {
        XCTAssertEqual(revnixBackgroundGround(try spec("{\"color\":\"#0B0D10\"}")), "#0B0D10")
    }

    func testTheLegacyGroundKeyIsStillAccepted() throws {
        XCTAssertEqual(revnixBackgroundGround(try spec("{\"ground\":\"#0B0D10\"}")), "#0B0D10")
    }

    func testAPlainStringIsTheLegacyGround() throws {
        XCTAssertEqual(revnixBackgroundGround(try spec("\"#0B0D10\"")), "#0B0D10")
    }

    func testAnEmptyOrAbsentGroundIsNilRatherThanAnEmptyPaint() throws {
        XCTAssertNil(revnixBackgroundGround(try spec(##"{"color":""}"##)))
        XCTAssertNil(revnixBackgroundGround(try spec("{}")))
        XCTAssertNil(revnixBackgroundGround(nil))
    }

    // MARK: - The layer stack

    func testALegacyStringResolvesToExactlyOneGroundLayer() throws {
        let layers = revnixBackgroundLayers(try spec("\"#0A0B0D\""))
        XCTAssertEqual(layers.ground, "#0A0B0D")
        XCTAssertNil(layers.image)
        XCTAssertNil(layers.overlay)
        XCTAssertTrue(layers.isGroundOnly)
    }

    func testAPhotoCarriesItsFitFocalPointOpacityAndBlur() throws {
        let layers = revnixBackgroundLayers(try spec("""
            {"color":"#000","image":{"url":"https://x/y.jpg","fit":"contain",
             "focalX":20,"focalY":35,"opacity":70,"blur":8}}
            """))
        let image = try XCTUnwrap(layers.image)
        XCTAssertEqual(image.url, "https://x/y.jpg")
        XCTAssertEqual(image.fit, .contain)
        XCTAssertEqual(image.focalX, 20)
        XCTAssertEqual(image.focalY, 35)
        XCTAssertEqual(image.opacity, 0.7, accuracy: 0.0001)
        XCTAssertEqual(image.blur, 8)
        XCTAssertFalse(layers.isGroundOnly)
    }

    func testPhotoDefaultsAreCoverCentredOpaqueAndUnblurred() throws {
        let layers = revnixBackgroundLayers(try spec(##"{"image":{"url":"https://x/y.jpg"}}"##))
        let image = try XCTUnwrap(layers.image)
        XCTAssertEqual(image.fit, .cover)
        XCTAssertEqual(image.focalX, 50)
        XCTAssertEqual(image.focalY, 50)
        XCTAssertEqual(image.opacity, 1)
        XCTAssertNil(image.blur)
    }

    func testLayersThatWouldDrawNothingAreDroppedRatherThanEmitted() throws {
        // A zero-opacity photo and a urlless one are both no-ops; emitting them
        // would cost a view that paints nothing.
        XCTAssertNil(revnixBackgroundLayers(try spec(##"{"image":{"fit":"cover"}}"##)).image)
        XCTAssertNil(
            revnixBackgroundLayers(try spec(##"{"image":{"url":"https://x/y.jpg","opacity":0}}"##)).image
        )
        XCTAssertNil(
            revnixBackgroundLayers(try spec(##"{"overlay":{"fill":"#000","opacity":0}}"##)).overlay
        )
    }

    func testFocalPointAndOpacityAreClampedToTheirRanges() throws {
        let layers = revnixBackgroundLayers(try spec("""
            {"image":{"url":"https://x/y.jpg","focalX":-40,"focalY":900,"opacity":400}}
            """))
        let image = try XCTUnwrap(layers.image)
        XCTAssertEqual(image.focalX, 0)
        XCTAssertEqual(image.focalY, 100)
        XCTAssertEqual(image.opacity, 1)
    }

    func testAScrimCarriesItsFillAndOpacity() throws {
        let layers = revnixBackgroundLayers(try spec("{\"overlay\":{\"fill\":\"#000000\",\"opacity\":40}}"))
        let overlay = try XCTUnwrap(layers.overlay)
        XCTAssertEqual(overlay.fill, "#000000")
        XCTAssertEqual(overlay.opacity, 0.4, accuracy: 0.0001)
    }

    // MARK: - @bg base colour

    private func base(_ css: String) -> String { revnixBackgroundBaseColor(css) }

    func testAStackedGradientAnswersWithTheBottomLayerNotTheGlowOnTop() {
        // In CSS the first-listed layer paints on top. The fixture stacks a
        // translucent lime glow over a near-black base; answering with the glow
        // would tint the whole screen lime.
        XCTAssertEqual(base(goldenGround), "#111820")
    }

    func testASingleGradientAnswersWithItsFirstStop() {
        XCTAssertEqual(base("linear-gradient(180deg, #111820, #07090C)"), "#111820")
        XCTAssertEqual(
            base("linear-gradient(180deg, rgba(0, 0, 0, 0.5), rgba(0, 0, 0, 1))"),
            "rgba(0, 0, 0, 0.5)"
        )
    }

    func testAFullyTransparentStopIsSkippedSinceItSaysNothingAboutTheGround() {
        XCTAssertEqual(base("linear-gradient(180deg, #D6FF3F00 0%, #111820 100%)"), "#111820")
    }

    func testAFlatColourAnswersWithItselfAndNothingAnswersBlack() {
        XCTAssertEqual(base("#0A0B0D"), "#0A0B0D")
        XCTAssertEqual(revnixBackgroundBaseColor(nil), "#000000")
        XCTAssertEqual(revnixBackgroundBaseColor("   "), "#000000")
    }

    // MARK: - The CSS gradient parser

    private func parse(_ css: String) -> [RevnixGradient] {
        revnixParseCssGradients(css, isColor: { Color(revnixBlockHex: $0) != nil })
    }

    func testAFlatColourIsNotAGradient() {
        XCTAssertTrue(parse("#0A0B0D").isEmpty)
    }

    func test180degRunsStraightDownWhichIsTheLibrarysMostCommonRecipe() throws {
        let gradients = parse("linear-gradient(180deg, #111820 0%, #07090C 100%)")
        XCTAssertEqual(gradients.count, 1)
        guard case let .linear(dirX, dirY, stops) = gradients[0] else {
            return XCTFail("expected a linear gradient")
        }
        XCTAssertEqual(dirX, 0, accuracy: 0.0001)
        XCTAssertEqual(dirY, 1, accuracy: 0.0001)
        XCTAssertEqual(stops.count, 2)
        XCTAssertEqual(stops[0].position, 0, accuracy: 0.0001)
        XCTAssertEqual(stops[1].position, 1, accuracy: 0.0001)
    }

    func test135degRunsCornerToCorner() throws {
        guard case let .linear(dirX, dirY, _) = parse("linear-gradient(135deg, #000 0%, #fff 100%)")[0]
        else { return XCTFail("expected a linear gradient") }
        XCTAssertEqual(dirX, 1, accuracy: 0.0001)
        XCTAssertEqual(dirY, 1, accuracy: 0.0001)
    }

    func testARadialGradientKeepsItsCentreAndExtent() throws {
        guard case let .radial(centerX, centerY, radius, stops) =
            parse("radial-gradient(120% 85% at 50% 0%, #D6FF3F38 0%, #D6FF3F00 58%)")[0]
        else { return XCTFail("expected a radial gradient") }
        XCTAssertEqual(centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(centerY, 0, accuracy: 0.0001)
        // CSS gives an ellipse; SwiftUI's RadialGradient is circular, so the
        // larger extent is used deliberately.
        XCTAssertEqual(radius, 1.2, accuracy: 0.0001)
        XCTAssertEqual(stops[1].position, 0.58, accuracy: 0.0001)
    }

    func testAStackedGradientComesBackBottomFirstReversingCssOwnOrder() {
        // In CSS the FIRST layer paints on top. The ZStack draws in sequence,
        // so the list is reversed on the way out — getting this backwards would
        // bury the glow under its own base.
        let gradients = parse(goldenGround)
        XCTAssertEqual(gradients.count, 2)
        if case .linear = gradients[0] {} else { XCTFail("expected the base linear first") }
        if case .radial = gradients[1] {} else { XCTFail("expected the glow on top") }
    }

    func testCommasInsideRgbaDoNotTearAStopInHalf() throws {
        guard case let .linear(_, _, stops) =
            parse("linear-gradient(180deg, rgba(0, 0, 0, 0.5) 0%, rgba(255, 255, 255, 1) 100%)")[0]
        else { return XCTFail("expected a linear gradient") }
        XCTAssertEqual(stops.count, 2)
    }

    func testStopsWithNoPositionAreInterpolatedTheWayCssSpacesThem() throws {
        guard case let .linear(_, _, stops) = parse("linear-gradient(180deg, #000, #888, #fff)")[0]
        else { return XCTFail("expected a linear gradient") }
        XCTAssertEqual(stops[0].position, 0, accuracy: 0.0001)
        XCTAssertEqual(stops[1].position, 0.5, accuracy: 0.0001)
        XCTAssertEqual(stops[2].position, 1, accuracy: 0.0001)
    }

    func testAKeywordDirectionIsUnderstoodAsWellAsAnAngle() throws {
        guard case let .linear(_, dirY, _) = parse("linear-gradient(to bottom, #000, #fff)")[0]
        else { return XCTFail("expected a linear gradient") }
        XCTAssertEqual(dirY, 1, accuracy: 0.0001)
    }

    func testAOneStopOrUnparseableGradientIsDroppedRatherThanHalfDrawn() {
        XCTAssertTrue(parse("linear-gradient(180deg, #000)").isEmpty)
        XCTAssertTrue(parse("conic-gradient(#000, #fff)").isEmpty)
        XCTAssertTrue(parse("linear-gradient(180deg, notacolour, alsonot)").isEmpty)
    }

    // MARK: - Focal-point cover geometry

    func testACentredFocalPointCropsEvenlyOnBothSides() {
        // A 200x100 photo into a 100x100 box: scaled to 200x100, 100 too wide,
        // centred means 50 hidden each side.
        let p = revnixCoverPlacement(
            box: (100, 100), source: (200, 100), focalX: 50, focalY: 50
        )
        XCTAssertEqual(p.width, 200, accuracy: 0.001)
        XCTAssertEqual(p.height, 100, accuracy: 0.001)
        XCTAssertEqual(p.left, -50, accuracy: 0.001)
        XCTAssertEqual(p.top, 0, accuracy: 0.001)
    }

    func testAFocalPointPullsTheCropTowardsTheSubject() {
        // focalX 0 keeps the left edge; focalX 100 keeps the right.
        XCTAssertEqual(
            revnixCoverPlacement(box: (100, 100), source: (200, 100), focalX: 0, focalY: 50).left,
            0, accuracy: 0.001
        )
        XCTAssertEqual(
            revnixCoverPlacement(box: (100, 100), source: (200, 100), focalX: 100, focalY: 50).left,
            -100, accuracy: 0.001
        )
    }

    func testTheCropNeverPullsAnImageEdgeInsideTheBox() {
        // An out-of-range focal point must still leave the box fully covered.
        let p = revnixCoverPlacement(
            box: (100, 100), source: (200, 100), focalX: 400, focalY: -400
        )
        XCTAssertGreaterThanOrEqual(p.left, -100)
        XCTAssertLessThanOrEqual(p.left, 0)
        XCTAssertEqual(p.top, 0, accuracy: 0.001)
    }

    func testADegenerateBoxOrSourceIsNotDividedBy() {
        let p = revnixCoverPlacement(box: (0, 0), source: (200, 100), focalX: 50, focalY: 50)
        XCTAssertEqual(p.width, 0)
        XCTAssertEqual(p.left, 0)
    }
}
