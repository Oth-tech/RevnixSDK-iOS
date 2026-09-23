import Foundation

#if canImport(StoreKit)
    import StoreKit
#endif

/// Coarse conversion value. Ours rather than Apple's
/// `SKAdNetwork.CoarseConversionValue`, which is iOS 16.1+ and would drag
/// `@available(iOS 16.1, *)` onto every signature that mentions it.
public enum RevnixCoarseValue: String, Sendable {
    case low
    case medium
    case high
}

enum RevnixSkan {
    static var isSupported: Bool {
        #if (os(iOS) || os(tvOS)) && canImport(StoreKit)
            true
        #else
            false
        #endif
    }

    static func update(_ value: Int, coarse: RevnixCoarseValue?, lockWindow: Bool) async throws {
        #if (os(iOS) || os(tvOS)) && canImport(StoreKit)
            if #available(iOS 16.1, tvOS 16.1, *), let coarse {
                let appleValue: SKAdNetwork.CoarseConversionValue =
                    switch coarse {
                    case .low: .low
                    case .medium: .medium
                    case .high: .high
                    }
                try await SKAdNetwork.updatePostbackConversionValue(
                    value, coarseValue: appleValue, lockWindow: lockWindow)
            } else {
                try await SKAdNetwork.updatePostbackConversionValue(value)
            }
        #else
            throw NSError(
                domain: "Revnix", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "SKAdNetwork is unavailable on this platform"
                ])
        #endif
    }
}
