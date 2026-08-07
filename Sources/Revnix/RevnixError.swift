import Foundation

/// Error taxonomy mirroring revnix-react: every case is either RETRYABLE
/// (transient — offline, timeout, 429, 5xx, captive portal) or DELIBERATE
/// (401/403/404/409 — the server refused on purpose; a kill-switch must
/// never be defeated by a cache or a retry).
public enum RevnixError: Error, Sendable, Equatable {
    /// Connectivity failure (offline, DNS, reset). Retryable.
    case network(String)
    /// Request exceeded the configured timeout. Retryable.
    case timeout
    /// HTTP 429. Retryable with backoff. Carries the server's `Retry-After`
    /// as milliseconds when it sent one.
    case rateLimited(retryAfterMs: Int?)
    /// HTTP 5xx. Retryable.
    case server(Int)
    /// A 200 whose body was not the expected JSON (captive portal). Retryable.
    case badResponse
    /// HTTP 401/403 — missing/refused key or key-kind. Deliberate.
    case auth(Int)
    /// HTTP 404 — unknown route/resource. Deliberate.
    case notFound
    /// HTTP 409 — purchase blocked by the app's transfer policy. Deliberate.
    case purchaseBlocked(String)
    /// Any other non-2xx (400 validation, 413 payload cap). Deliberate.
    case invalid(Int, String)

    public var isRetryable: Bool {
        switch self {
        case .network, .timeout, .rateLimited, .server, .badResponse:
            return true
        case .auth, .notFound, .purchaseBlocked, .invalid:
            return false
        }
    }

    /// Server-advised wait before retrying, when it sent one (429 only).
    public var retryAfterMs: Int? {
        if case .rateLimited(let ms) = self { return ms }
        return nil
    }

    static func fromHTTP(
        status: Int, message: String, retryAfter: String? = nil
    ) -> RevnixError {
        switch status {
        case 401, 403: return .auth(status)
        case 404: return .notFound
        case 409: return .purchaseBlocked(message)
        case 429: return .rateLimited(retryAfterMs: parseRetryAfter(retryAfter))
        case 500...599: return .server(status)
        default: return .invalid(status, message)
        }
    }

    /// `Retry-After` is either delta-seconds or an HTTP date (RFC 9110).
    static func parseRetryAfter(
        _ raw: String?, now: Date = Date()
    ) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        if let seconds = Double(raw) {
            return seconds > 0 ? Int(seconds * 1000) : 0
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, Int(date.timeIntervalSince(now) * 1000))
    }
}
