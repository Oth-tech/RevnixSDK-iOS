import Foundation
import XCTest

@testable import Revnix

/// Designed-paywall tests.
///
/// The block document is authored by a dashboard that ships independently of
/// this SDK and reaches the app over the network, so the emphasis here is the
/// two guarantees an app cannot be patched into later: a document from a NEWER
/// dashboard still decodes and still renders, and a tag with no data behind it
/// never resolves to a price the store will not charge.
final class PaywallBlockTests: XCTestCase {

    // MARK: - Fixtures

    private func decodeDoc(_ json: String) throws -> PaywallBlockDoc {
        try JSONDecoder().decode(PaywallBlockDoc.self, from: Data(json.utf8))
    }

    private func decodeConfig(_ json: String) throws -> PaywallConfig {
        try JSONDecoder().decode(PaywallConfig.self, from: Data(json.utf8))
    }

    private static let palette = """
        "version":1,"background":"#101014","textColor":"#F5F7FA",
        "accent":"#6478ff","accentInk":"#0B0D10"
        """

    private static let annual = RevnixPaywallPackage(
        packageId: "annual", title: "Annual", priceLabel: "$59.99",
        period: "annual", amountMinor: 5999, currency: "USD"
    )
    private static let monthly = RevnixPaywallPackage(
        packageId: "monthly", title: "Monthly", priceLabel: "$9.99",
        period: "monthly", amountMinor: 999, currency: "USD"
    )
    private var packages: [RevnixPaywallPackage] { [Self.annual, Self.monthly] }

    // MARK: - Decoding the nine block types

    func testDecodesAllNineBlockTypes() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"t","type":"text","text":"Headline"},
              {"id":"i","type":"image","placeholder":"hero"},
              {"id":"l","type":"list","items":[{"title":"Offline downloads"}]},
              {"id":"p","type":"products"},
              {"id":"b","type":"button","label":"Continue"},
              {"id":"k","type":"links"},
              {"id":"n","type":"line"},
              {"id":"s","type":"spacer","flex":true},
              {"id":"c","type":"card","layout":"row","children":[{"id":"c1","type":"text","text":"in"}]}
            ]}
            """)
        XCTAssertEqual(doc.blocks.count, 9)
        guard case .text = doc.blocks[0] else { return XCTFail("expected text") }
        guard case .image = doc.blocks[1] else { return XCTFail("expected image") }
        guard case let .list(list) = doc.blocks[2] else { return XCTFail("expected list") }
        XCTAssertEqual(list.items.first?.title, "Offline downloads")
        guard case .products = doc.blocks[3] else { return XCTFail("expected products") }
        guard case let .button(button) = doc.blocks[4] else { return XCTFail("expected button") }
        XCTAssertEqual(button.label, "Continue")
        guard case .links = doc.blocks[5] else { return XCTFail("expected links") }
        guard case .line = doc.blocks[6] else { return XCTFail("expected line") }
        guard case let .spacer(spacer) = doc.blocks[7] else { return XCTFail("expected spacer") }
        XCTAssertEqual(spacer.flex, true)
        guard case let .card(card) = doc.blocks[8] else { return XCTFail("expected card") }
        XCTAssertEqual(card.layout, "row")
        XCTAssertEqual(card.children.count, 1)
    }

    func testDecodesTheFourContainerLayouts() throws {
        for layout in ["column", "row", "stack", "grid"] {
            let doc = try decodeDoc("""
                {\(Self.palette),"blocks":[{"id":"c","type":"card","layout":"\(layout)","children":[]}]}
                """)
            guard case let .card(card) = doc.blocks[0] else { return XCTFail("expected card") }
            XCTAssertEqual(card.layout, layout)
        }
    }

    // MARK: - A shipped app cannot be patched

    func testUnknownBlockTypeDecodesAsUnknownAndKeepsItsSiblings() throws {
        // A block type introduced after this SDK shipped must cost its own
        // node, not the screen.
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"a","type":"text","text":"before"},
              {"id":"x","type":"hologram","spin":true},
              {"id":"b","type":"text","text":"after"}
            ]}
            """)
        XCTAssertEqual(doc.blocks.count, 3)
        guard case .unknown = doc.blocks[1] else { return XCTFail("expected unknown") }
        guard case let .text(first) = doc.blocks[0] else { return XCTFail("expected text") }
        guard case let .text(last) = doc.blocks[2] else { return XCTFail("expected text") }
        XCTAssertEqual(first.text, "before")
        XCTAssertEqual(last.text, "after")
    }

    func testUnknownStyleFieldIsIgnoredAndTheKnownOnesSurvive() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"t","type":"text","text":"x","style":{"fontSize":22,"teleport":"yes","radius":8}}
            ]}
            """)
        guard case let .text(text) = doc.blocks[0] else { return XCTFail("expected text") }
        XCTAssertEqual(text.style?.fontSize, 22)
        XCTAssertEqual(text.style?.radius, 8)
    }

    func testStyleFieldOfAnUnexpectedTypeCostsOnlyThatField() throws {
        // A future dashboard could widen a field's type. That must degrade to
        // "this SDK ignores it", not to a failed decode.
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"t","type":"text","text":"x","style":{"fontSize":"huge","radius":8}}
            ]}
            """)
        guard case let .text(text) = doc.blocks[0] else { return XCTFail("expected text") }
        XCTAssertNil(text.style?.fontSize)
        XCTAssertEqual(text.style?.radius, 8)
    }

    func testMalformedBlockDecodesAsUnknownRatherThanThrowing() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":["not-a-block",{"id":"a","type":"text","text":"survivor"}]}
            """)
        XCTAssertEqual(doc.blocks.count, 2)
        guard case .unknown = doc.blocks[0] else { return XCTFail("expected unknown") }
    }

    func testDocumentWithNoBlocksIsRejectedSoTheClassicLayoutRenders() {
        XCTAssertThrowsError(try decodeDoc("{\(Self.palette),\"blocks\":[]}"))
    }

    func testAMalformedTreeNeverCostsTheWholeConfig() throws {
        // The critical degradation: if `blocks` cannot be read, the app must
        // still get a classic paywall it can sell from — never nothing.
        let config = try decodeConfig("""
            {"template":"focus","headline":"Go Pro","ctaLabel":"Continue",
             "features":[],"blocks":"this is not a document"}
            """)
        XCTAssertNil(config.blocks)
        XCTAssertEqual(config.headline, "Go Pro")
        XCTAssertEqual(config.template, "focus")
    }

    func testAConfigWithoutBlocksStillDecodesUnchanged() throws {
        let config = try decodeConfig("""
            {"template":"minimal","headline":"Go Pro","ctaLabel":"Start","features":[]}
            """)
        XCTAssertNil(config.blocks)
        XCTAssertEqual(config.template, "minimal")
    }

    func testAConfigWithBlocksExposesTheTree() throws {
        let config = try decodeConfig("""
            {"template":"focus","headline":"Go Pro","ctaLabel":"Continue","features":[],
             "blocks":{\(Self.palette),"blocks":[{"id":"t","type":"text","text":"Designed"}]}}
            """)
        XCTAssertEqual(config.blocks?.blocks.count, 1)
        XCTAssertEqual(config.blocks?.accent, "#6478ff")
    }

    func testReEncodingKeepsFieldsThisSdkDoesNotModel() throws {
        // A config that round-trips through the SDK must come out the same
        // size it went in, or a newer dashboard's field is silently lost.
        let config = try decodeConfig("""
            {"template":"focus","headline":"Go Pro","ctaLabel":"Continue","features":[],
             "blocks":{\(Self.palette),"futureField":"keep me",
             "blocks":[{"id":"t","type":"text","text":"Designed"}]}}
            """)
        let data = try JSONEncoder().encode(config)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("keep me"), "unmodelled fields must survive a round trip")
    }

    // MARK: - Tag variables

    func testPriceComesFromTheStoreNotTheDesign() {
        XCTAssertEqual(revnixResolveTags("{price}", package: Self.annual, all: packages), "$59.99")
        XCTAssertEqual(
            revnixResolveTags("{title} — {price}", package: Self.annual, all: packages),
            "Annual — $59.99"
        )
        XCTAssertEqual(
            revnixResolveTags("every {period}", package: Self.monthly, all: packages),
            "every month"
        )
        XCTAssertEqual(
            revnixResolveTags("{price}/{period_short}", package: Self.annual, all: packages),
            "$59.99/yr"
        )
    }

    func testATagWithNoDataBehindItStaysVisible() {
        // No period and no money: a guess here would be a price the store will
        // not charge, so the tag must remain on screen instead.
        let bare = RevnixPaywallPackage(packageId: "x", title: "Pro", priceLabel: "$1")
        XCTAssertEqual(revnixResolveTags("{price_per_month}", package: bare, all: [bare]), "{price_per_month}")
        XCTAssertEqual(revnixResolveTags("{save_percent}", package: bare, all: [bare]), "{save_percent}")
        XCTAssertEqual(revnixResolveTags("{period}", package: bare, all: [bare]), "{period}")
    }

    func testUnknownTagIsLeftInPlace() {
        XCTAssertEqual(
            revnixResolveTags("{quantum_discount}", package: Self.annual, all: packages),
            "{quantum_discount}"
        )
    }

    func testSavingIsComputedAgainstTheDearestPlan() {
        XCTAssertEqual(revnixResolveTags("{save_percent}", package: Self.annual, all: packages), "50%")
        // The dearest plan has nothing to beat, so its saving stays unresolved.
        XCTAssertEqual(
            revnixResolveTags("{save_percent}", package: Self.monthly, all: packages),
            "{save_percent}"
        )
    }

    func testCurrenciesWithoutAMinorUnitAreNotDividedByAHundred() {
        XCTAssertEqual(revnixMinorUnits(for: "JPY"), 1)
        XCTAssertEqual(revnixMinorUnits(for: "USD"), 100)
        let yen = RevnixPaywallPackage(
            packageId: "y", title: "Year", priceLabel: "¥12,000",
            period: "annual", amountMinor: 12000, currency: "JPY"
        )
        // 12,000 yen a year is 1,000 a month — not 10.
        XCTAssertTrue(
            revnixResolveTags("{price_per_month}", package: yen, all: [yen]).contains("1,000"),
            "a currency with no minor unit must not be divided by 100"
        )
    }

    func testAnUnclosedBraceIsLeftAloneRatherThanEatingTheRestOfTheCopy() {
        XCTAssertEqual(
            revnixResolveTags("Save {price on this", package: Self.annual, all: packages),
            "Save {price on this"
        )
    }

    func testTextWithNoTagsIsUntouched() {
        XCTAssertEqual(
            revnixResolveTags("Train smarter", package: Self.annual, all: packages),
            "Train smarter"
        )
    }

    // MARK: - Palette tokens

    func testPaletteTokensResolveAgainstTheScreenPalette() throws {
        let doc = try decodeDoc("{\(Self.palette),\"blocks\":[{\"id\":\"t\",\"type\":\"text\",\"text\":\"x\"}]}")
        XCTAssertNotNil(revnixBlockColor("@accent", doc))
        XCTAssertNotNil(revnixBlockColor("@text/12", doc))
        XCTAssertNotNil(revnixBlockColor("#ff0000", doc))
        XCTAssertNotNil(revnixBlockColor("rgba(255, 0, 0, 0.5)", doc))
        // A gradient has no single colour; the caller keeps its own default.
        XCTAssertNil(revnixBlockColor("linear-gradient(180deg,#000,#fff)", doc))
        XCTAssertNil(revnixBlockColor("@nonsense", doc))
    }

    func testLayeredBackgroundReducesToItsGroundColour() throws {
        let doc = try decodeDoc("""
            {"version":1,"background":{"ground":"#0B0D10","image":{"url":"https://x/y.jpg"}},
             "textColor":"#fff","accent":"#6478ff","accentInk":"#000",
             "blocks":[{"id":"t","type":"text","text":"x"}]}
            """)
        XCTAssertEqual(doc.background, "#0B0D10")
    }

    // MARK: - Style values

    func testProportionalAndAutoValuesSurviveDecoding() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[{"id":"t","type":"text","text":"x","style":{
              "height":"78%","top":"50%","left":24,"marginTop":"auto","aspectRatio":"16/9","basis":250
            }}]}
            """)
        guard case let .text(text) = doc.blocks[0], let style = text.style else {
            return XCTFail("expected a styled text block")
        }
        XCTAssertEqual(style.height?.fraction, 0.78)
        XCTAssertNil(style.height?.points, "a percentage has no fixed point value")
        XCTAssertEqual(style.top?.fraction, 0.5)
        XCTAssertEqual(style.left?.points, 24)
        XCTAssertEqual(style.marginTop?.isAuto, true)
        XCTAssertEqual(style.aspectRatio?.ratio, 16.0 / 9.0)
        XCTAssertEqual(style.basis, 250)
    }

    func testPerSideBordersDecode() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[{"id":"t","type":"text","text":"x","style":{
              "borderTop":"2px solid @accent","borderBottom":"1px solid @text/12"
            }}]}
            """)
        guard case let .text(text) = doc.blocks[0] else { return XCTFail("expected text") }
        XCTAssertEqual(text.style?.borderTop, "2px solid @accent")
        XCTAssertEqual(text.style?.borderBottom, "1px solid @text/12")
    }

    func testSelectedStyleMergesOverTheBaseStyle() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[{"id":"c","type":"card","repeat":"packages",
              "style":{"radius":16,"fill":"#111"},
              "selectedStyle":{"fill":"@accent/12"},
              "children":[]}]}
            """)
        guard case let .card(card) = doc.blocks[0] else { return XCTFail("expected card") }
        let merged = (card.style ?? BlockStyle()).merging(card.selectedStyle)
        XCTAssertEqual(merged.fill, "@accent/12", "the selected style wins where it sets a field")
        XCTAssertEqual(merged.radius, 16, "and the base style survives where it does not")
    }

    func testGridTrackListAndColumnCountBothDecode() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"g1","type":"card","layout":"grid","columns":3,"children":[]},
              {"id":"g2","type":"card","layout":"grid","gridColumns":"1fr 60px","children":[]}
            ]}
            """)
        guard case let .card(byCount) = doc.blocks[0] else { return XCTFail("expected card") }
        guard case let .card(byTracks) = doc.blocks[1] else { return XCTFail("expected card") }
        XCTAssertEqual(byCount.columns, 3)
        XCTAssertEqual(byTracks.gridColumns, "1fr 60px")
    }

    func testPackageIndexAndRepeatDecode() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"a","type":"card","packageIndex":1,"children":[]},
              {"id":"b","type":"card","repeat":"packages","children":[]}
            ]}
            """)
        guard case let .card(pinned) = doc.blocks[0] else { return XCTFail("expected card") }
        guard case let .card(repeated) = doc.blocks[1] else { return XCTFail("expected card") }
        XCTAssertEqual(pinned.packageIndex, 1)
        XCTAssertEqual(repeated.repeatMode, "packages")
    }
}
