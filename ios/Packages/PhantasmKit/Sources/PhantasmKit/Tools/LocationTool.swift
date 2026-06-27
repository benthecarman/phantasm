import Foundation

/// A resolved device location: coordinates plus optional reverse-geocoded place
/// fields. A pure value (no CoreLocation types) so `PhantasmKit` stays
/// host-testable — the app maps `CLPlacemark`/`CLLocation` into this.
public struct DeviceLocation: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Horizontal accuracy in meters, if known (nil/<=0 → omitted).
    public var horizontalAccuracy: Double?
    /// Reverse-geocoded fields (any may be nil if geocoding failed or is sparse).
    public var placeName: String?
    public var locality: String?
    public var administrativeArea: String?
    public var postalCode: String?
    public var country: String?

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double? = nil,
        placeName: String? = nil,
        locality: String? = nil,
        administrativeArea: String? = nil,
        postalCode: String? = nil,
        country: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.placeName = placeName
        self.locality = locality
        self.administrativeArea = administrativeArea
        self.postalCode = postalCode
        self.country = country
    }
}

/// Why a location lookup couldn't produce a fix. Each case carries a
/// model-facing message that folds into the tool result (NFR-O6: never fatal).
public enum LocationLookupError: Error, Sendable, Equatable {
    /// The user denied location permission.
    case permissionDenied
    /// Location is unavailable for policy reasons (parental controls, MDM).
    case restricted
    /// A generic failure (services off, no fix, geocoder error) with detail.
    case unavailable(String)

    /// The sentence shown to the model so it can recover (e.g. ask the user to
    /// enable location, or proceed without it).
    public var modelMessage: String {
        switch self {
        case .permissionDenied:
            return "the user has not granted location permission. Ask them to enable "
                + "Location for this app in Settings, or proceed without their location."
        case .restricted:
            return "location access is restricted on this device and can't be used."
        case .unavailable(let detail):
            return detail
        }
    }
}

/// Provides the device's current location. Implemented in the app target with
/// CoreLocation (which lives there, keeping this package free of it); the tool
/// holds an injected provider so its formatting stays pure/testable.
public protocol LocationProviding: Sendable {
    func currentLocation() async -> Result<DeviceLocation, LocationLookupError>
}

/// The app-hosted `get_current_location` tool. Like `current_time` it needs no
/// UI — the device answers the forwarded call itself (an `AutoResolvedTool`) and
/// the turn continues. The actual fix comes from an injected `LocationProviding`
/// (CoreLocation, app side); the formatting is pure/static so it's host-testable.
public struct LocationTool: AutoResolvedTool {
    private let provider: any LocationProviding

    public init(provider: any LocationProviding) {
        self.provider = provider
    }

    public let name = ToolName.location
    public var statusText: String? { "checking location…" }

    public var spec: ToolSpec {
        ToolSpec(
            name: ToolName.location,
            description: "Get the user's current geographic location (latitude/longitude "
                + "plus a reverse-geocoded place name, city, region, and country). Use it "
                + "whenever a request depends on where the user is — \"weather near me\", "
                + "\"restaurants nearby\", \"what time zone am I in\", local recommendations. "
                + "Takes no arguments. The device may prompt the user for permission the "
                + "first time; if permission is denied the result says so and you should "
                + "proceed without their location or ask them to enable it.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        )
    }

    public func resolve(_ call: WireToolCall) async -> String {
        switch await provider.currentLocation() {
        case .success(let location):
            return Self.format(location)
        case .failure(let error):
            return "get_current_location failed: \(error.modelMessage)"
        }
    }

    /// Render the answer block (pure, host-testable). Mirrors `current_time`'s
    /// `label: value` line shape so the model sees a familiar structure.
    public static func format(_ location: DeviceLocation) -> String {
        var lines = ["Current location:"]
        if let place = placeLine(location) {
            lines.append("place: \(place)")
        }
        if let postalCode = trimmed(location.postalCode) {
            lines.append("postal_code: \(postalCode)")
        }
        lines.append("latitude: \(coordinate(location.latitude))")
        lines.append("longitude: \(coordinate(location.longitude))")
        if let accuracy = location.horizontalAccuracy, accuracy > 0 {
            lines.append("accuracy: within \(Int(accuracy.rounded())) m")
        }
        return lines.joined(separator: "\n")
    }

    /// Human-readable place, e.g. "Apple Park, Cupertino, California, United States".
    /// Built from whatever components reverse-geocoding returned, dropping nils and
    /// any component that just repeats the previous one. Nil if none are present.
    private static func placeLine(_ location: DeviceLocation) -> String? {
        let components = [
            location.placeName, location.locality,
            location.administrativeArea, location.country,
        ]
        var parts: [String] = []
        for component in components {
            guard let value = trimmed(component) else { continue }
            if value.caseInsensitiveCompare(parts.last ?? "") == .orderedSame { continue }
            parts.append(value)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Six-decimal fixed coordinate (~0.1 m precision), locale-independent.
    private static func coordinate(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
