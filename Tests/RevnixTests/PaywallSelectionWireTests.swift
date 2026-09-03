import XCTest

@testable import Revnix

/// The designed-paywall selection contract (render contract v2, REV-262).
///
/// `paywall-selection-wire.json` is a byte-identical copy of the fixture every
/// renderer — the dashboard preview, React Native, Android, Flutter, Unity,
/// Capacitor — walks in its own suite. Each case fixes a host selection and a
/// highlight and states what every block must resolve to: its effective
/// style, whether it is drawn, and its copy with tags filled in. The cases run
/// through the same pure functions the SwiftUI interpreter applies per block,
/// so a renderer that passes here draws what the others draw.
final class PaywallSelectionWireTests: XCTestCase {

    // MARK: - Fixture

    private struct Fixture: Decodable {
        struct Package: Decodable {
            let packageId: String
            let title: String
            let priceLabel: String
            let period: String?
            let amountMinor: Int?
            let currency: String?
        }

        struct Case: Decodable {
            let name: String
            let selected: String?
            let highlight: String?
            let styles: [String: BlockStyle]
            let visible: [String]
            let hidden: [String]
            let texts: [String: String]
        }

        let doc: PaywallBlockDoc
        let packages: [Package]
        let cases: [Case]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "paywall-selection-wire", withExtension: "json")
        )
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func packages(_ fixture: Fixture) -> [RevnixPaywallPackage] {
        fixture.packages.map {
            RevnixPaywallPackage(
                packageId: $0.packageId, title: $0.title, priceLabel: $0.priceLabel,
                period: $0.period, amountMinor: $0.amountMinor, currency: $0.currency
            )
        }
    }

    /// A style as the JSON object it encodes to, so an expectation can name
    /// any subset of fields and only those are compared.
    private func fields(_ style: BlockStyle?) throws -> [String: RevnixJSONValue] {
        let data = try JSONEncoder().encode(style ?? BlockStyle())
        guard case let .object(object) = try JSONDecoder().decode(RevnixJSONValue.self, from: data) else {
            return [:]
        }
        return object
    }

    private func assertStyle(
        _ actual: BlockStyle?, matches expected: BlockStyle, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let got = try fields(actual)
        for (key, value) in try fields(expected) {
            XCTAssertEqual(got[key], value, "\(label): \(key)", file: file, line: line)
        }
    }

    // MARK: - The shared cases

    func testEveryCaseInTheSharedFixtureResolvesAsTheContractSays() throws {
        let fixture = try fixture()
        let packages = packages(fixture)
        XCTAssertEqual(fixture.cases.count, 4, "the fixture carries four cases")

        for c in fixture.cases {
            let selected = revnixSelectedPackageId(
                host: c.selected, internal: nil, highlight: c.highlight, packages: packages
            )
            let resolved = revnixResolveBlockTree(fixture.doc, packages: packages, selectedPackageId: selected)
            func block(_ id: String) throws -> RevnixResolvedBlock {
                try XCTUnwrap(resolved.first { $0.id == id }, "\(c.name): block \(id) was not resolved")
            }

            for (id, expected) in c.styles {
                try assertStyle(try block(id).style, matches: expected, "\(c.name): \(id)")
            }
            for id in c.visible {
                XCTAssertTrue(try block(id).visible, "\(c.name): \(id) must be drawn")
            }
            for id in c.hidden {
                XCTAssertFalse(try block(id).visible, "\(c.name): \(id) must not be drawn")
            }
            for (id, text) in c.texts {
                XCTAssertEqual(try block(id).text, text, "\(c.name): \(id)")
            }
        }
    }

    func testTheFixtureDecodesTheNewFieldsOnNestedBlocks() throws {
        let doc = try fixture().doc
        let resolved = revnixResolveBlockTree(doc, packages: [], selectedPackageId: nil)
        // Pinned cards vanish with no offering, so only the root-level blocks
        // resolve — and the root text with `visibility` is still drawn.
        XCTAssertEqual(resolved.map(\.id), ["plans", "footer", "root-hidden", "cta"])
        XCTAssertTrue(try XCTUnwrap(resolved.first { $0.id == "root-hidden" }).visible)
        // With nothing to resolve against, the renewal line keeps its tags
        // visible rather than inventing a price.
        XCTAssertEqual(
            try XCTUnwrap(resolved.first { $0.id == "footer" }).text,
            "7 days free, then {price}/{period_short}. Cancel anytime."
        )
    }

    // MARK: - Selected package

    private static let monthly = RevnixPaywallPackage(
        packageId: "monthly", title: "Monthly", priceLabel: "$9.99", period: "monthly",
        amountMinor: 999, currency: "USD"
    )
    private static let yearly = RevnixPaywallPackage(
        packageId: "yearly", title: "Yearly", priceLabel: "$59.99", period: "annual",
        amountMinor: 5999, currency: "USD"
    )
    private var offering: [RevnixPaywallPackage] { [Self.monthly, Self.yearly] }

    func testTheHostSelectionWinsWhenItNamesAnOfferedPackage() {
        XCTAssertEqual(
            revnixSelectedPackageId(host: "yearly", internal: "monthly", highlight: "monthly", packages: offering),
            "yearly"
        )
    }

    func testAHostSelectionTheOfferingDoesNotContainFallsThrough() {
        XCTAssertEqual(
            revnixSelectedPackageId(host: "lifetime", internal: "yearly", highlight: nil, packages: offering),
            "yearly", "to the renderer's own selection"
        )
        XCTAssertEqual(
            revnixSelectedPackageId(host: "lifetime", internal: "gone", highlight: "yearly", packages: offering),
            "yearly", "then to the highlight"
        )
        XCTAssertEqual(
            revnixSelectedPackageId(host: "lifetime", internal: nil, highlight: "gone", packages: offering),
            "monthly", "then to the first package"
        )
        XCTAssertNil(revnixSelectedPackageId(host: "monthly", internal: nil, highlight: nil, packages: []))
    }

    // MARK: - Context, style, visibility

    private func decodeDoc(_ json: String) throws -> PaywallBlockDoc {
        try JSONDecoder().decode(PaywallBlockDoc.self, from: Data(json.utf8))
    }

    private static let palette = """
        "version":1,"background":"#101014","textColor":"#F5F7FA",
        "accent":"#6478ff","accentInk":"#0B0D10"
        """

    func testSelectedStyleAndVisibilityDecodeOnEveryBlockType() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"t","type":"text","text":"x","selectedStyle":{"fill":"#1"},"visibility":"selected"},
              {"id":"i","type":"image","selectedStyle":{"fill":"#1"},"visibility":"unselected"},
              {"id":"l","type":"list","items":[],"selectedStyle":{"fill":"#1"},"visibility":"selected"},
              {"id":"p","type":"products","selectedStyle":{"fill":"#1"},"visibility":"selected"},
              {"id":"b","type":"button","label":"x","selectedStyle":{"fill":"#1"},"visibility":"selected"},
              {"id":"k","type":"links","selectedStyle":{"fill":"#1"},"visibility":"selected"},
              {"id":"n","type":"line","selectedStyle":{"fill":"#1"},"visibility":"selected"},
              {"id":"s","type":"spacer","selectedStyle":{"fill":"#1"},"visibility":"selected"},
              {"id":"c","type":"card","children":[],"selectedStyle":{"fill":"#1"},"visibility":"selected"},
              {"id":"u","type":"text","text":"x","visibility":"sometimes"}
            ]}
            """)
        for block in doc.blocks.dropLast() {
            XCTAssertEqual(block.selectedStyle?.fill, "#1", block.id)
            XCTAssertEqual(block.visibility, block.id == "i" ? .unselected : .selected, block.id)
        }
        XCTAssertNil(doc.blocks.last?.visibility, "a value this SDK does not know means always drawn")
    }

    func testOutsideAPackageCardSelectedStyleAndVisibilityAreIgnored() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"t","type":"text","text":"x","style":{"fill":"#111"},
               "selectedStyle":{"fill":"#222"},"visibility":"selected"}
            ]}
            """)
        let block = doc.blocks[0]
        XCTAssertEqual(revnixSelectionContext(package: nil, selectedPackageId: "monthly"), .outsidePackage)
        XCTAssertEqual(revnixEffectiveStyle(block, in: .outsidePackage)?.fill, "#111")
        XCTAssertTrue(revnixIsBlockVisible(block, in: .outsidePackage))
        XCTAssertEqual(revnixEffectiveStyle(block, in: .selected)?.fill, "#222")
        XCTAssertFalse(revnixIsBlockVisible(block, in: .unselected))
    }

    func testARepeatedCardJudgesEachInstanceAgainstItsOwnPackage() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"r","type":"card","repeat":"packages","style":{"fill":"#111"},
               "selectedStyle":{"fill":"#222"},"children":[
                 {"id":"tick","type":"text","text":"{title}","visibility":"selected"},
                 {"id":"wrap","type":"card","children":[
                   {"id":"deep","type":"text","text":"{price}","visibility":"unselected"}
                 ]}
              ]}
            ]}
            """)
        let resolved = revnixResolveBlockTree(doc, packages: offering, selectedPackageId: "yearly")
        XCTAssertEqual(
            resolved.map(\.id), ["r", "tick", "wrap", "deep", "r", "tick", "wrap", "deep"],
            "one instance per package, children included"
        )
        let monthly = Array(resolved[0 ..< 4]), yearly = Array(resolved[4 ..< 8])
        XCTAssertEqual(monthly[0].context, .unselected)
        XCTAssertEqual(monthly[0].style?.fill, "#111")
        XCTAssertFalse(monthly[1].visible)
        XCTAssertEqual(monthly[2].context, .unselected, "a plain card inherits its row's context")
        XCTAssertTrue(monthly[3].visible)
        XCTAssertEqual(monthly[3].text, "$9.99", "tags inside the row resolve against the row's package")
        XCTAssertEqual(yearly[0].context, .selected)
        XCTAssertEqual(yearly[0].style?.fill, "#222")
        XCTAssertTrue(yearly[1].visible)
        XCTAssertEqual(yearly[1].text, "Yearly")
        XCTAssertFalse(yearly[3].visible)
    }

    func testTheChildrenOfAHiddenBlockAreHiddenWithIt() throws {
        let doc = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"c0","type":"card","packageIndex":0,"children":[
                {"id":"ring","type":"card","visibility":"selected","children":[
                  {"id":"dot","type":"text","text":"x"}
                ]}
              ]}
            ]}
            """)
        let resolved = revnixResolveBlockTree(doc, packages: offering, selectedPackageId: "yearly")
        XCTAssertEqual(resolved.map(\.visible), [true, false, false])
    }

    // MARK: - The fallback close

    func testAConditionalCloseDoesNotSuppressTheFallbackChip() throws {
        let conditional = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"x","type":"button","label":"Not now","action":"close","visibility":"selected"}
            ]}
            """)
        XCTAssertFalse(revnixHasCloseAction(conditional.blocks))

        let inConditionalCard = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"c","type":"card","visibility":"unselected","children":[
                {"id":"x","type":"text","text":"×","action":"close"}
              ]}
            ]}
            """)
        XCTAssertFalse(revnixHasCloseAction(inConditionalCard.blocks))

        let certain = try decodeDoc("""
            {\(Self.palette),"blocks":[
              {"id":"c","type":"card","children":[
                {"id":"x","type":"text","text":"×","action":"close"}
              ]}
            ]}
            """)
        XCTAssertTrue(revnixHasCloseAction(certain.blocks))
    }

    // MARK: - Canvas

    func testTheAuthoredScreenRendersOneToOneAndDoesNotScroll() {
        let m = revnixCanvasMetrics(viewportWidth: 393, viewportHeight: 852)
        XCTAssertEqual(m.scale, 1)
        XCTAssertEqual(m.layoutHeight, 852)
        XCTAssertTrue(m.fits)
    }

    func testAShorterScreenScalesByWidthAndScrolls() {
        let m = revnixCanvasMetrics(viewportWidth: 375, viewportHeight: 667)
        XCTAssertEqual(m.scale, 375 / 393, accuracy: 0.0001)
        XCTAssertEqual(m.layoutHeight, 852, "the design keeps its authored height")
        XCTAssertGreaterThan(m.scaledHeight, 667)
        XCTAssertFalse(m.fits, "and the viewport scrolls to reach the CTA")
    }

    func testATallerScreenFillsRatherThanLeavingABand() {
        let m = revnixCanvasMetrics(viewportWidth: 430, viewportHeight: 932)
        XCTAssertEqual(m.scale, 430 / 393, accuracy: 0.0001)
        XCTAssertEqual(m.scaledHeight, 932, accuracy: 0.5)
        XCTAssertTrue(m.fits)
        let taller = revnixCanvasMetrics(viewportWidth: 393, viewportHeight: 1000)
        XCTAssertEqual(taller.layoutHeight, 1000, "the layout grows in design units to fill")
        XCTAssertTrue(taller.fits)
    }

    func testATabletCapsTheScaleAndCentresTheDesign() {
        let m = revnixCanvasMetrics(viewportWidth: 1024, viewportHeight: 1366)
        XCTAssertEqual(m.scale, 480 / 393, accuracy: 0.0001)
        XCTAssertLessThan(m.scaledWidth, 1024, "the background fills around it")
        XCTAssertEqual(m.scaledHeight, 1366, accuracy: 0.5)
        XCTAssertTrue(m.fits)
    }

    func testLandscapeCapsTheScaleAndScrolls() {
        let m = revnixCanvasMetrics(viewportWidth: 852, viewportHeight: 393)
        XCTAssertEqual(m.scale, 480 / 393, accuracy: 0.0001)
        XCTAssertEqual(m.layoutHeight, 852)
        XCTAssertFalse(m.fits)
    }

    func testAZeroSizedFirstPassDoesNotDivideByZero() {
        let m = revnixCanvasMetrics(viewportWidth: 0, viewportHeight: 0)
        XCTAssertEqual(m.scale, 1)
        XCTAssertEqual(m.layoutHeight, 852)
        XCTAssertTrue(m.scale.isFinite && m.layoutHeight.isFinite)
    }
}
