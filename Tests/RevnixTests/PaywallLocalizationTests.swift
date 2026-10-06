import Foundation
import XCTest

@testable import Revnix

/// REV-271 designed-paywall localization.
///
/// The dashboard writes the table; this SDK reads it. These are the parity
/// contract — the same cases run in revnix-app and in every other Revnix SDK,
/// so a paywall translated in the builder resolves identically everywhere.
///
/// The guarantees that matter are the ones a shipped app cannot be patched
/// out of: an untranslated string must never render blank, a regional locale
/// must reach its language, and the overlay must disturb nothing but words.
final class PaywallLocalizationTests: XCTestCase {

    override func tearDown() {
        RevnixClient.setLocale(nil)
        super.tearDown()
    }

    private static let doc = """
        {
          "version": 1, "background": "#101014", "textColor": "#F5F7FA",
          "accent": "#6478ff", "accentInk": "#0B0D10",
          "defaultLocale": "en",
          "locales": {
            "es": {
              "hed.text": "Desbloquea Pro",
              "feats.items.0.title": "Modo sin conexión",
              "plans.priceTpl": "{price}/mes",
              "cta.label": "Continuar"
            },
            "pt_br": { "hed.text": "Desbloqueie o Pro" }
          },
          "blocks": [
            { "id": "hed", "type": "text", "text": "Unlock Pro", "style": { "fontSize": 28 } },
            { "id": "feats", "type": "list", "items": [
                { "title": "Offline mode", "description": "Take it anywhere" },
                { "title": "No ads" } ] },
            { "id": "wrap", "type": "card", "layout": "column", "children": [
                { "id": "plans", "type": "products", "titleTpl": "{title}", "priceTpl": "{price}/mo" },
                { "id": "cta", "type": "button", "label": "Continue" } ] }
          ]
        }
        """

    private func decoded() throws -> PaywallBlockDoc {
        try JSONDecoder().decode(PaywallBlockDoc.self, from: Data(Self.doc.utf8))
    }

    private func text(_ block: PaywallBlock?) -> String? {
        if case let .text(b) = block { return b.text }
        return nil
    }

    private func label(_ block: PaywallBlock?) -> String? {
        if case let .button(b) = block { return b.label }
        return nil
    }

    private func children(_ block: PaywallBlock?) -> [PaywallBlock] {
        if case let .card(b) = block { return b.children }
        return []
    }

    // MARK: - Tags

    func testNormalizesTagsToOneCanonicalForm() {
        XCTAssertEqual(revnixNormalizeLocale("es_mx"), "es-MX")
        XCTAssertEqual(revnixNormalizeLocale(" PT-br "), "pt-BR")
        XCTAssertEqual(revnixNormalizeLocale("zh-hans-cn"), "zh-Hans-CN")
        XCTAssertEqual(revnixNormalizeLocale("es-419"), "es-419")
        // Junk must not become a language nobody can select.
        XCTAssertNil(revnixNormalizeLocale("english"))
        XCTAssertNil(revnixNormalizeLocale(""))
    }

    func testAuthoredTagsAreNormalizedOnDecode() throws {
        // "pt_br" was hand-written in the catalog; a device reporting "pt-BR"
        // must still find it.
        let doc = try decoded()
        XCTAssertNotNil(doc.localization.tables["pt-BR"])
        XCTAssertEqual(text(doc.localized("pt-BR").blocks.first), "Desbloqueie o Pro")
    }

    // MARK: - Fallback chain

    func testRegionalLocaleFallsBackToItsLanguageNotToEnglish() {
        XCTAssertEqual(
            revnixLocaleChain(available: ["es", "fr"], locale: "es-MX", defaultLocale: "en"),
            ["es"]
        )
        // Deterministic across devices: dictionary order must not decide what
        // a customer reads.
        XCTAssertEqual(
            revnixLocaleChain(available: ["es-MX", "es-AR"], locale: "es", defaultLocale: nil),
            ["es-AR"]
        )
        XCTAssertEqual(
            revnixLocaleChain(available: ["es"], locale: "ja", defaultLocale: nil),
            []
        )
    }

    // MARK: - Applying a language

    func testSwapsStringsAtEveryDepth() throws {
        let out = try decoded().localized("es-MX")
        XCTAssertEqual(text(out.blocks.first), "Desbloquea Pro")
        let inner = children(out.blocks.last)
        XCTAssertEqual(label(inner.last), "Continuar")
        if case let .products(b) = inner.first {
            // The tag survives translation, so {price} still resolves after it.
            XCTAssertEqual(b.priceTpl, "{price}/mes")
            XCTAssertEqual(b.titleTpl, "{title}")
        } else {
            XCTFail("expected a products block")
        }
    }

    func testUntranslatedStringsKeepTheAuthoredCopy() throws {
        let out = try decoded().localized("es")
        guard case let .list(list) = out.blocks[1] else { return XCTFail("expected a list") }
        XCTAssertEqual(list.items[0].title, "Modo sin conexión")
        // Same item, untranslated description — and a wholly untranslated row.
        XCTAssertEqual(list.items[0].description, "Take it anywhere")
        XCTAssertEqual(list.items[1].title, "No ads")
    }

    func testEmptyTranslationMeansUntranslatedNotBlank() throws {
        // An export/import round-trip leaves empty cells everywhere; honouring
        // them would ship a paywall with no CTA label.
        let json = Self.doc.replacingOccurrences(
            of: "\"cta.label\": \"Continuar\"", with: "\"cta.label\": \"\""
        )
        let doc = try JSONDecoder().decode(PaywallBlockDoc.self, from: Data(json.utf8))
        XCTAssertEqual(label(children(doc.localized("es").blocks.last).last), "Continue")
    }

    func testOnlyWordsChange() throws {
        let original = try decoded()
        let out = original.localized("es")
        XCTAssertEqual(out.accent, original.accent)
        XCTAssertEqual(out.background, original.background)
        XCTAssertEqual(out.blocks.first?.id, "hed")
        if case let .text(b) = out.blocks[0] {
            XCTAssertEqual(b.style?.fontSize, 28)
        } else {
            XCTFail("expected a text block")
        }
    }

    func testUnmatchedLocaleAndUntranslatedPaywallRenderAsAuthored() throws {
        let out = try decoded().localized("ja")
        XCTAssertEqual(text(out.blocks.first), "Unlock Pro")

        let plain = """
            {"version":1,"background":"#000","textColor":"#fff","accent":"#6478ff",
             "accentInk":"#fff","blocks":[{"id":"hed","type":"text","text":"Unlock Pro"}]}
            """
        let doc = try JSONDecoder().decode(PaywallBlockDoc.self, from: Data(plain.utf8))
        XCTAssertTrue(doc.localization.isEmpty)
        XCTAssertEqual(text(doc.localized("es").blocks.first), "Unlock Pro")
    }

    func testMalformedTableCostsTheTranslationsNotThePaywall() throws {
        let json = """
            {"version":1,"background":"#000","textColor":"#fff","accent":"#6478ff",
             "accentInk":"#fff","locales":"nonsense",
             "blocks":[{"id":"hed","type":"text","text":"Unlock Pro"}]}
            """
        let doc = try JSONDecoder().decode(PaywallBlockDoc.self, from: Data(json.utf8))
        XCTAssertTrue(doc.localization.isEmpty)
        XCTAssertEqual(text(doc.localized("es").blocks.first), "Unlock Pro")
    }

    func testLocalizedSetsDefaultLocaleToTheResolvedLanguage() throws {
        let out = try decoded().localized("es-MX")
        XCTAssertEqual(out.localization.defaultLocale, "es")
    }

    func testLinkLabelsResolveUrdu() {
        XCTAssertEqual(revnixLinkLabels("ur").restore, "بحال کریں")
        XCTAssertEqual(revnixLinkLabels("ur-PK").restore, "بحال کریں")
    }

    func testLinkLabelsPickTraditionalChineseForTaiwanHongKong() {
        XCTAssertEqual(revnixLinkLabels("zh-Hant-TW").restore, "恢復購買")
        XCTAssertEqual(revnixLinkLabels("zh-TW").restore, "恢復購買")
        XCTAssertEqual(revnixLinkLabels("zh-HK").restore, "恢復購買")
    }

    func testLinkLabelsPickSimplifiedChineseOtherwise() {
        XCTAssertEqual(revnixLinkLabels("zh-Hans-HK").restore, "恢复购买")
        XCTAssertEqual(revnixLinkLabels("zh-CN").restore, "恢复购买")
        XCTAssertEqual(revnixLinkLabels("zh").restore, "恢复购买")
    }

    func testLinkLabelsResolveAliasedTags() {
        XCTAssertEqual(revnixLinkLabels("iw").restore, "שחזור")
        XCTAssertEqual(revnixLinkLabels("no").restore, "Gjenopprett")
    }

    func testLinkLabelsFallBackToEnglish() {
        XCTAssertEqual(revnixLinkLabels("xx").restore, "Restore")
        XCTAssertEqual(revnixLinkLabels(nil).restore, "Restore")
        XCTAssertEqual(revnixLinkLabels("").restore, "Restore")
    }

    func testLinkLabelsNormalizeUnderscoredTags() {
        XCTAssertEqual(revnixLinkLabels("pt_BR").restore, "Restaurar")
    }

    func testSetLocaleOverridesTheDeviceLocaleUntilCleared() {
        let device = revnixDeviceLocale()
        RevnixClient.setLocale("ur")
        XCTAssertEqual(revnixDeviceLocale(), "ur")
        RevnixClient.setLocale(nil)
        XCTAssertEqual(revnixDeviceLocale(), device)
        RevnixClient.setLocale("ur")
        RevnixClient.setLocale("")
        XCTAssertEqual(revnixDeviceLocale(), device)
    }
}
