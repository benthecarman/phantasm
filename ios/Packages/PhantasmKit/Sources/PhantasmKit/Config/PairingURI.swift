import Foundation

/// The `phantasm://pair` URI (SPEC §2.2d, docs/qr-pairing.md): QR payload and
/// deep link carrying `{url, token?, name?}` — everything a backend profile
/// needs. Pure parse/generate logic so it's host-testable; camera scanning and
/// QR rendering live in the app target.
public enum PairingURI {
    public static let scheme = "phantasm"
    public static let authority = "pair"
    public static let version = "1"

    public enum ParseError: Error, Equatable, Sendable {
        /// Wrong scheme/authority — not a pairing URI at all (a caller
        /// handling arbitrary deep links should ignore, not alert).
        case notPairingURI
        /// `v` missing or not one we understand — the producer is newer than
        /// this app. Never partially import.
        case unsupportedVersion
        /// `url` missing, unparseable, or not http(s).
        case badBackendURL

        /// User-facing text, kept beside the enum (the `AppError.userMessage`
        /// precedent) so exhaustiveness and wording are host-testable. The
        /// deep-link path ignores `.notPairingURI` (a URL that isn't ours is
        /// not an error); the in-app scanner *does* surface it as a hint,
        /// since there the user explicitly aimed at a code.
        public var userMessage: String {
            switch self {
            case .notPairingURI:
                return "This isn't a Phantasm pairing code."
            case .unsupportedVersion:
                return "This pairing code was made for a newer version of Phantasm. Update the app and try again."
            case .badBackendURL:
                return "This pairing code doesn't contain a valid backend address."
            }
        }
    }

    /// Parse a scanned or deep-linked URI. Unknown query params are ignored
    /// (forward compatibility — breaking changes bump `v` instead).
    public static func parse(_ url: URL) throws -> PairingPayload {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == authority,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw ParseError.notPairingURI
        }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            // First occurrence wins; duplicates in a hand-mangled URI shouldn't
            // let a later value silently override the scanned one.
            if params[item.name] == nil { params[item.name] = item.value ?? "" }
        }
        guard params["v"] == version else { throw ParseError.unsupportedVersion }
        guard let rawURL = params["url"] else { throw ParseError.badBackendURL }
        let normalized = BackendProfile.normalizedBaseURLString(rawURL)
        guard let backend = URL(string: normalized),
              let backendScheme = backend.scheme?.lowercased(),
              ["http", "https"].contains(backendScheme),
              backend.host != nil
        else {
            throw ParseError.badBackendURL
        }
        return PairingPayload(
            baseURLString: normalized,
            token: nonEmpty(params["token"]),
            name: nonEmpty(params["name"])
        )
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }
}

/// A parsed (or to-be-shared) pairing. The token is held only transiently —
/// callers move it to the Keychain on save and never persist the payload.
public struct PairingPayload: Equatable, Sendable {
    public var baseURLString: String
    public var token: String?
    public var name: String?

    public init(baseURLString: String, token: String? = nil, name: String? = nil) {
        self.baseURLString = baseURLString
        self.token = token
        self.name = name
    }

    /// Profile name to propose in the confirmation sheet: explicit `name`,
    /// else the backend host.
    public var displayName: String {
        name ?? URL(string: baseURLString)?.host ?? baseURLString
    }

    /// The saved profile this payload targets, matched by canonical URL —
    /// host case and default ports must not defeat the match (the
    /// orchestrator's URL serializer lowercases and drops them; hand-typed
    /// profiles may not).
    public func matchingProfile(in profiles: [BackendProfile]) -> BackendProfile? {
        let target = BackendProfile.canonicalBaseURLString(baseURLString)
        return profiles.first {
            BackendProfile.canonicalBaseURLString($0.baseURLString) == target
        }
    }


    /// Render back to the URI string (the app's "Show pairing QR" share path).
    /// Values are RFC 3986 percent-encoded component-wise — never `+`-for-
    /// space, and `&`/`=` inside values always escaped — matching the
    /// orchestrator's `pair` subcommand byte-for-byte for the same inputs.
    public var uri: String {
        var out = "\(PairingURI.scheme)://\(PairingURI.authority)?v=\(PairingURI.version)"
        out += "&url=\(Self.encodeComponent(baseURLString))"
        if let token {
            out += "&token=\(Self.encodeComponent(token))"
        }
        if let name {
            out += "&name=\(Self.encodeComponent(name))"
        }
        return out
    }

    /// RFC 3986 unreserved set only, like JS `encodeURIComponent` but stricter
    /// (also escapes `!*'()`). `.urlQueryAllowed` is too loose here: it leaves
    /// `+`, `&`, and `=` bare, which corrupts values under query parsing.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encodeComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}
