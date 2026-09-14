import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// REV-272: implicit placements — the six moments the SDK reports on its own.
///
/// A placement is normally a location the HOST resolves by name, so every new
/// place a paywall could appear costs a code change and an App Store release.
/// Six moments are the same in every app and visible to the SDK without the
/// host saying anything, so an operator can attach a paywall to them from the
/// dashboard alone.
///
/// Mirrors `convex/lib/implicitPlacements.ts` in revnix-app and
/// `src/implicit.ts` in revnix-react — the backend owns the key spellings, and
/// a mismatch here is silent (the server 400s a key it does not know), so the
/// list is asserted against the documented contract in the tests.
public enum RevnixImplicitPlacement: String, Sendable, CaseIterable {
    case appInstall = "app_install"
    case appLaunch = "app_launch"
    case sessionStart = "session_start"
    /// Lowercase, not Superwall's `deepLink_open`: a placement key must match
    /// `^[a-z0-9][a-z0-9._-]{0,63}$` server-side.
    case deeplinkOpen = "deeplink_open"
    case paywallDecline = "paywall_decline"
    case transactionAbandon = "transaction_abandon"
}

/// The placementKey a dashboard QR/link preview resolution carries
/// (`<scheme>://revnix-preview?revnix_preview=<token>`, handed to
/// `handleDeepLink`). Not one of the six above and never sent to
/// `/v1/placements/triggered` — detect a preview via
/// `resolution.placementKey == revnixPreviewPlacementKey` (or
/// `resolution.preview == true`).
public let revnixPreviewPlacementKey = "revnix_preview"

/// What the host is handed when a moment resolved to a paywall. Only ever
/// delivered WITH a paywall — a moment the server answered with none (nothing
/// attached, or the same paywall the customer is leaving) is reported and
/// then dropped, since there is nothing to present.
public struct RevnixImplicitTrigger: Sendable {
    /// Which of the six fired.
    public let placement: RevnixImplicitPlacement
    /// The resolution, exactly as `resolvePlacement` would have returned it.
    public let resolution: PlacementResolution
}

/// Where the app is. Both transitions matter: a session is defined by how
/// long the app was in the BACKGROUND, which cannot be known from foreground
/// events alone — "time since the last return" would mint a session after 35
/// minutes of continuous use plus a three-second app switch.
public enum RevnixAppState: Sendable {
    case foreground
    case background
}

/// How the SDK learns the app's foreground/background transitions, which is
/// what `session_start` is built on.
///
/// The default (`RevnixAppLifecycle.system`) listens for UIKit's
/// `didBecomeActive` / `didEnterBackground` notifications where UIKit exists,
/// and does nothing on platforms without it. Inject your own on an AppKit
/// host, in a test, or wherever you already track these transitions.
public struct RevnixAppLifecycle: Sendable {
    /// Subscribe to app state transitions. Returns a cancel closure; the
    /// client calls it when the client is torn down. Repeated reports of the
    /// same state are harmless.
    public let onStateChange:
        @Sendable (@escaping @Sendable (RevnixAppState) -> Void) -> (@Sendable () -> Void)

    public init(
        onStateChange: @escaping @Sendable (@escaping @Sendable (RevnixAppState) -> Void) -> (
            @Sendable () -> Void
        )
    ) {
        self.onStateChange = onStateChange
    }

    /// UIKit's own notifications, or a no-op where UIKit is absent.
    /// `didBecomeActive` rather than `willEnterForeground` for the return, and
    /// `didEnterBackground` for the departure — the pair whose gap is the time
    /// the customer was actually away.
    public static let system = RevnixAppLifecycle { handler in
        #if canImport(UIKit) && !os(watchOS)
            let center = NotificationCenter.default
            let active = center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
            ) { _ in handler(.foreground) }
            let background = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
            ) { _ in handler(.background) }
            return {
                center.removeObserver(active)
                center.removeObserver(background)
            }
        #else
            return {}
        #endif
    }

    /// Foreground detection off. Launch-time moments still fire.
    public static let disabled = RevnixAppLifecycle { _ in {} }
}

/// How long the app must have been backgrounded for the return to count as a
/// new session rather than an app switch. Matches Superwall's own definition
/// so a team moving over gets the same numbers.
public let revnixDefaultSessionTimeout: TimeInterval = 30 * 60
