import Foundation

/// User-facing error taxonomy (FR-A10). Distinguishes the three things the user
/// needs to act on differently: the backend is unreachable, auth is wrong, or
/// the model/stream itself failed.
public enum AppError: Error, Sendable, Equatable {
    /// DNS/connection refused/timeout — backend not reachable.
    case unreachable
    /// HTTP 401/403 — bad or missing token.
    case authFailed
    /// HTTP 404 — used to *degrade* (no manifest), not a hard error.
    case notFound
    /// HTTP 5xx, an OpenAI error body, or a malformed stream.
    case modelError(String)
    /// Could not decode a response.
    case decoding(String)
    /// The user cancelled (stop button) — not shown as an error.
    case cancelled

    public var userMessage: String {
        switch self {
        case .unreachable: return "Backend unreachable. Check the URL and your connection."
        case .authFailed: return "Authentication failed. Check your token in Settings."
        case .notFound: return "Endpoint not found."
        case .modelError(let detail): return "The model returned an error: \(detail)"
        case .decoding(let detail): return "Couldn’t read the response: \(detail)"
        case .cancelled: return "Cancelled."
        }
    }

    /// Map a transport/HTTP error into the taxonomy.
    public static func from(_ error: Error) -> AppError {
        if error is CancellationError { return .cancelled }
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .cannotConnectToHost, .cannotFindHost, .timedOut,
                 .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed:
                return .unreachable
            default:
                return .modelError(urlError.localizedDescription)
            }
        }
        return .modelError(error.localizedDescription)
    }

    /// Map an HTTP status code to an error, or `nil` if it's a success.
    public static func fromStatus(_ status: Int) -> AppError? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .authFailed
        case 404: return .notFound
        default: return .modelError("HTTP \(status)")
        }
    }
}
