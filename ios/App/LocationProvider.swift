import CoreLocation
import PhantasmKit

/// CoreLocation-backed `LocationProviding` for the app-hosted `get_current_location`
/// tool. Lives in the app target (CoreLocation is kept out of `PhantasmKit` so the
/// package stays host-testable); `PhantasmKit`'s `LocationTool` holds this behind
/// the `LocationProviding` protocol and does the (pure) formatting.
///
/// On `currentLocation()` it ensures When-In-Use authorization (prompting on first
/// use), takes a single fix via `requestLocation()`, then best-effort reverse
/// geocodes it. Every failure maps to a `LocationLookupError` the tool folds into
/// its result, so a denied permission or missing fix is recoverable, never fatal.
@MainActor
final class LocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    /// Continuations waiting on the authorization prompt / a one-shot fix. Arrays
    /// because callers could overlap; each resumes exactly once when its phase
    /// completes.
    private var authContinuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private var fixContinuations: [CheckedContinuation<Result<CLLocation, LocationLookupError>, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Prompt for When-In-Use authorization now, if the user hasn't yet decided.
    /// Called the moment the location tool is enabled for a chat, so the system
    /// permission sheet appears on that tap rather than on the model's first call.
    /// No-op once a decision exists (granted, denied, or restricted).
    func requestAuthorizationWhenInUse() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func currentLocation() async -> Result<DeviceLocation, LocationLookupError> {
        let status = await ensureAuthorized()
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        case .denied:
            return .failure(.permissionDenied)
        case .restricted:
            return .failure(.restricted)
        case .notDetermined:
            return .failure(.unavailable("the location permission prompt was dismissed."))
        @unknown default:
            return .failure(.unavailable("location is unavailable on this device."))
        }

        let clLocation: CLLocation
        switch await requestFix() {
        case .success(let location): clLocation = location
        case .failure(let error): return .failure(error)
        }

        let placemark = await reverseGeocode(clLocation)
        return .success(Self.deviceLocation(from: clLocation, placemark: placemark))
    }

    // MARK: - Authorization

    private func ensureAuthorized() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            authContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        // Ignore the initial `.notDetermined` callback delivered before the prompt
        // is answered; only resume once the user has decided.
        guard status != .notDetermined else { return }
        Task { @MainActor in
            let waiting = authContinuations
            authContinuations.removeAll()
            for continuation in waiting { continuation.resume(returning: status) }
        }
    }

    // MARK: - One-shot fix

    private func requestFix() async -> Result<CLLocation, LocationLookupError> {
        await withCheckedContinuation { continuation in
            fixContinuations.append(continuation)
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        resumeFix(with: .success(location))
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let mapped: LocationLookupError
        if let clError = error as? CLError {
            switch clError.code {
            case .denied: mapped = .permissionDenied
            default: mapped = .unavailable("couldn't determine the current location.")
            }
        } else {
            mapped = .unavailable("couldn't determine the current location.")
        }
        resumeFix(with: .failure(mapped))
    }

    private nonisolated func resumeFix(with result: Result<CLLocation, LocationLookupError>) {
        Task { @MainActor in
            let waiting = fixContinuations
            fixContinuations.removeAll()
            for continuation in waiting { continuation.resume(returning: result) }
        }
    }

    // MARK: - Reverse geocoding

    /// Best-effort: a geocoder failure just yields nil so the tool returns
    /// coordinates without a place name.
    private func reverseGeocode(_ location: CLLocation) async -> CLPlacemark? {
        try? await geocoder.reverseGeocodeLocation(location).first
    }

    private static func deviceLocation(
        from location: CLLocation, placemark: CLPlacemark?
    ) -> DeviceLocation {
        DeviceLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            placeName: placemark?.name,
            locality: placemark?.locality,
            administrativeArea: placemark?.administrativeArea,
            postalCode: placemark?.postalCode,
            country: placemark?.country
        )
    }
}
