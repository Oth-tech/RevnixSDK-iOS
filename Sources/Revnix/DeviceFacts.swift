import Foundation

/// REV-268: the device attribute contract, SDK side. Every Revnix SDK sends
/// the same facts about the device on each placement resolve, in the
/// `X-Revnix-Device` header, and the server stores them as reserved
/// `device.*` customer attributes — what a targeting rule ("US storefront",
/// "app version at least 3", "first open") evaluates against on the very
/// request that serves the paywall.
///
/// `detect()` fills everything Foundation can answer synchronously. The
/// storefront is StoreKit's and asynchronous, so the client fetches it once
/// on the first resolve (RevnixClient.deviceHeader) unless the app already
/// set it here. The SDK adds `sdkVersion`, `installedAt` and `firstOpen`
/// itself. Every field is optional: the server treats a missing fact as
/// missing, never as an error.
public struct DeviceFacts: Sendable, Equatable {
    /// "ios", "macos", "tvos", "watchos", "visionos".
    public var platform: String?
    /// e.g. "18.1".
    public var osVersion: String?
    /// `CFBundleShortVersionString`, e.g. "1.2.10". The server derives the
    /// zero-padded sortable form (`device.appVersionPadded`) from it.
    public var appVersion: String?
    /// `Locale.current.identifier`, e.g. "en_US" (the server normalizes).
    public var locale: String?
    /// ISO 4217, e.g. "USD".
    public var currency: String?
    /// App Store storefront country, alpha-3 as StoreKit reports it ("USA");
    /// the server normalizes to alpha-2. Nil = let the client ask StoreKit.
    public var storefront: String?
    /// Hardware identifier, e.g. "iPhone15,3".
    public var model: String?
    /// True for a sandbox receipt (development, TestFlight) or a DEBUG build.
    public var sandbox: Bool?

    public init(
        platform: String? = nil,
        osVersion: String? = nil,
        appVersion: String? = nil,
        locale: String? = nil,
        currency: String? = nil,
        storefront: String? = nil,
        model: String? = nil,
        sandbox: Bool? = nil
    ) {
        self.platform = platform
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.locale = locale
        self.currency = currency
        self.storefront = storefront
        self.model = model
        self.sandbox = sandbox
    }

    /// What this process can say about itself without asking StoreKit.
    public static func detect() -> DeviceFacts {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var osVersion = "\(os.majorVersion).\(os.minorVersion)"
        if os.patchVersion > 0 { osVersion += ".\(os.patchVersion)" }
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let locale = Locale.current
        var currency: String?
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            currency = locale.currency?.identifier
        } else {
            currency = locale.currencyCode
        }
        return DeviceFacts(
            platform: Self.platformName,
            osVersion: osVersion,
            appVersion: appVersion,
            locale: locale.identifier,
            currency: currency,
            storefront: nil,
            model: Self.modelIdentifier(),
            sandbox: Self.isSandbox(bundle: bundle)
        )
    }

    static var platformName: String {
        #if os(visionOS)
            return "visionos"
        #elseif os(iOS)
            return "ios"
        #elseif os(tvOS)
            return "tvos"
        #elseif os(watchOS)
            return "watchos"
        #elseif os(macOS)
            return "macos"
        #else
            return "apple"
        #endif
    }

    /// `utsname.machine` — "iPhone15,3" on device. The simulator reports
    /// the host's architecture there, so it is asked for the model it is
    /// simulating instead.
    static func modelIdentifier() -> String? {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        let machine = withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return machine.isEmpty ? nil : machine
    }

    /// Sandbox receipts (development, TestFlight) live at
    /// `…/sandboxReceipt`; a DEBUG build is sandbox by definition.
    static func isSandbox(bundle: Bundle) -> Bool {
        #if DEBUG
            return true
        #else
            return bundle.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    /// The wire payload for one resolve: these facts plus the SDK-owned ones,
    /// encoded as base64url of the UTF-8 JSON. Fields that are nil are left
    /// out — the server would drop them, and bytes on every resolve are bytes
    /// on every resolve.
    func encodedHeader(
        sdkVersion: String, installedAt: Int?, firstOpen: Bool?
    ) -> String? {
        var payload: [String: JSONValue] = ["sdkVersion": .string(sdkVersion)]
        if let v = platform { payload["platform"] = .string(v) }
        if let v = osVersion { payload["osVersion"] = .string(v) }
        if let v = appVersion { payload["appVersion"] = .string(v) }
        if let v = locale { payload["locale"] = .string(v) }
        if let v = currency { payload["currency"] = .string(v) }
        if let v = storefront { payload["storefront"] = .string(v) }
        if let v = model { payload["model"] = .string(v) }
        if let v = sandbox { payload["sandbox"] = .bool(v) }
        if let v = installedAt { payload["installedAt"] = .number(Double(v)) }
        if let v = firstOpen { payload["firstOpen"] = .bool(v) }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
