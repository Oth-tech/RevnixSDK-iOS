import Foundation

#if canImport(AppTrackingTransparency)
    import AppTrackingTransparency
#endif
#if canImport(AdSupport)
    import AdSupport
#endif

struct RevnixTracking: Sendable {
    var status: @Sendable () -> Int
    var request: @Sendable () async -> Int
    var idfa: @Sendable () -> String?

    static let statusNames = ["not_determined", "restricted", "denied", "authorized"]

    static let system = RevnixTracking(
        status: {
            #if canImport(AppTrackingTransparency)
                Int(ATTrackingManager.trackingAuthorizationStatus.rawValue)
            #else
                -1
            #endif
        },
        request: { await prompt() },
        idfa: {
            #if canImport(AdSupport)
                let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                return id == "00000000-0000-0000-0000-000000000000" ? nil : id
            #else
                return nil
            #endif
        }
    )

    @MainActor private static func prompt() async -> Int {
        #if canImport(AppTrackingTransparency)
            Int(await ATTrackingManager.requestTrackingAuthorization().rawValue)
        #else
            -1
        #endif
    }
}
