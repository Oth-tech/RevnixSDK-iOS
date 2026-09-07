import Foundation

// REV-271: paywall localization. A designed paywall carries ONE tree plus a
// side table of translated strings — never one tree per language — so styles,
// layout and block ids are shared and only words differ.
//
// Selection happens HERE, at render, rather than server-side at resolve. The
// resolution is cached on the device, so a locale chosen by the server would
// pin a cached paywall to whatever language it was fetched in: change the
// phone's language and the old copy would keep rendering until the cache
// expired, and offline it would never change at all.
//
// Mirrored across all six Revnix SDKs — keep the key scheme, the fallback
// chain and the field list identical.

/// The translations published with a document: `defaultLocale` names the
/// language the tree itself is written in, and `locales` maps a BCP-47 tag to
/// a flat `<blockId>.<path>` → string table.
public struct PaywallLocalization: Sendable, Equatable {
    public var defaultLocale: String?
    public var tables: [String: [String: String]]

    public init(defaultLocale: String? = nil, tables: [String: [String: String]] = [:]) {
        self.defaultLocale = defaultLocale
        self.tables = tables
    }

    public var isEmpty: Bool { tables.isEmpty }
}

/// BCP-47, hyphenated: "es_MX" and "es-mx" both normalize to "es-MX". Applied
/// to authored tags and to the device's own locale alike, so the two can never
/// miss each other over punctuation or case. Nil for anything that is not a
/// language tag, which keeps junk out of the lookup instead of into it.
public func revnixNormalizeLocale(_ tag: String?) -> String? {
    guard let tag else { return nil }
    let parts = tag.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "_", with: "-")
        .split(separator: "-")
        .map(String.init)
    guard let first = parts.first else { return nil }
    let language = first.lowercased()
    guard language.count >= 2, language.count <= 3,
          language.allSatisfy({ $0.isASCII && $0.isLetter })
    else { return nil }
    var rest: [String] = []
    for part in parts.dropFirst() {
        let letters = part.allSatisfy { $0.isASCII && $0.isLetter }
        let digits = part.allSatisfy { $0.isASCII && $0.isNumber }
        let alnum = part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        // Region subtags are uppercase ("MX", "419"), scripts title case
        // ("Hans"); anything else is a variant and stays lowercase. A subtag
        // outside BCP-47's shapes makes the WHOLE tag junk rather than passing
        // through — otherwise a device reporting "es-!!" would look up a
        // language.
        if part.count == 2 && letters {
            rest.append(part.uppercased())
        } else if part.count == 3 && digits {
            rest.append(part)
        } else if part.count == 4 && letters {
            rest.append(part.prefix(1).uppercased() + part.dropFirst().lowercased())
        } else if (5...8).contains(part.count) && alnum {
            rest.append(part.lowercased())
        } else {
            return nil
        }
    }
    return ([language] + rest).joined(separator: "-")
}

private func revnixBaseLanguage(_ tag: String) -> String {
    String(tag.split(separator: "-").first ?? Substring(tag))
}

/// Which tables to consult, most specific first.
///
/// "es-MX" on a paywall translated into "es" reads the "es" table: a regional
/// variant that was never authored falls back to its language rather than to
/// the source, which is the difference between a Mexican customer reading
/// Spanish and reading English. The authored tree is the last resort and is
/// deliberately NOT in this chain — the lookup falls through to it.
public func revnixLocaleChain(
    available: [String], locale: String?, defaultLocale: String?
) -> [String] {
    var chain: [String] = []
    func push(_ tag: String?) {
        guard let tag, available.contains(tag), !chain.contains(tag) else { return }
        chain.append(tag)
    }
    if let wanted = revnixNormalizeLocale(locale) {
        push(wanted)
        push(revnixBaseLanguage(wanted))
        // "es" asked for, only "es-MX" authored: one regional table beats the
        // source language, and the first SORTED match keeps the choice
        // deterministic across devices rather than dictionary-order dependent.
        if chain.isEmpty {
            let language = revnixBaseLanguage(wanted)
            push(available.filter { revnixBaseLanguage($0) == language }.sorted().first)
        }
    }
    push(revnixNormalizeLocale(defaultLocale))
    return chain
}

/// The device's language. `Locale.preferredLanguages` is the user's ordered
/// list — the first entry is what every other iOS surface localizes to, so a
/// paywall matching it matches the rest of the app.
public func revnixDeviceLocale() -> String? {
    Locale.preferredLanguages.first ?? Locale.current.identifier
}

// MARK: - Applying a language

private func revnixLocalize(
    _ block: PaywallBlock, _ lookup: (String, String) -> String
) -> PaywallBlock {
    switch block {
    case var .text(b):
        b.text = lookup("\(b.id).text", b.text)
        return .text(b)
    case var .button(b):
        b.label = lookup("\(b.id).label", b.label)
        return .button(b)
    case var .list(b):
        b.items = b.items.enumerated().map { index, item in
            var item = item
            item.title = lookup("\(b.id).items.\(index).title", item.title)
            if let description = item.description {
                item.description = lookup("\(b.id).items.\(index).description", description)
            }
            return item
        }
        return .list(b)
    case var .products(b):
        if let value = b.titleTpl { b.titleTpl = lookup("\(b.id).titleTpl", value) }
        if let value = b.priceTpl { b.priceTpl = lookup("\(b.id).priceTpl", value) }
        if let value = b.highlightSub { b.highlightSub = lookup("\(b.id).highlightSub", value) }
        if let value = b.badgeText { b.badgeText = lookup("\(b.id).badgeText", value) }
        return .products(b)
    case var .card(b):
        b.children = b.children.map { revnixLocalize($0, lookup) }
        return .card(b)
    default:
        return block
    }
}

extension PaywallBlockDoc {
    /// Returns the document with every string swapped for `locale`'s.
    ///
    /// Applied ONCE before rendering rather than at each text node: the views
    /// below then need no localization awareness at all, and the six SDKs
    /// cannot drift on which fields are translatable. Returns `self` untouched
    /// when nothing applies, so an untranslated paywall costs nothing.
    ///
    /// `{price}` and the other copy tags survive, because they are resolved
    /// AFTER this on the localized string — "Solo {price} al mes" works.
    public func localized(_ locale: String?) -> PaywallBlockDoc {
        guard !localization.isEmpty else { return self }
        let chain = revnixLocaleChain(
            available: Array(localization.tables.keys),
            locale: locale,
            defaultLocale: localization.defaultLocale
        )
        guard !chain.isEmpty else { return self }
        let tables = localization.tables
        let lookup: (String, String) -> String = { key, authored in
            for tag in chain {
                // An empty translation means "not translated", never "render
                // nothing": a blank CTA is a dead paywall, and export/import
                // round-trips leave empty cells behind for untouched rows.
                if let value = tables[tag]?[key], !value.isEmpty { return value }
            }
            return authored
        }
        var copy = self
        copy.blocks = blocks.map { revnixLocalize($0, lookup) }
        return copy
    }
}
