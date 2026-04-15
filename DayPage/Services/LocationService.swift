import Foundation
import CoreLocation

// MARK: - LocationService

/// Wraps CLLocationManager to provide a simple async-based API for:
///   1. Requesting "while-in-use" location permission
///   2. Fetching current GPS coordinates (one-shot)
///   3. Reverse-geocoding coordinates to a human-readable place name
///
/// Usage:
///   let loc = try await LocationService.shared.currentLocation(timeout: 3)
///
@MainActor
final class LocationService: NSObject, ObservableObject {

    // MARK: Singleton

    static let shared = LocationService()

    // MARK: Published

    /// Current authorization status; UI can observe this to show permission prompts.
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Most recently resolved location result (name + coordinates).
    @Published var lastLocation: Memo.Location? = nil

    // MARK: Private

    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    // MARK: - Init

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        authorizationStatus = manager.authorizationStatus
    }

    // MARK: - Public API

    /// Requests "when-in-use" authorization if not yet determined.
    /// Call from the main thread before calling `currentLocation()`.
    func requestPermissionIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    /// Fetches the current GPS location and reverse-geocodes it into a `Memo.Location`.
    ///
    /// - Parameter timeout: Seconds to wait before falling back to coordinates-only (default 3s).
    /// - Throws: `LocationError.denied` if permission is denied/restricted.
    /// - Returns: A `Memo.Location` with `lat`/`lng` always set; `name` set when geocoding succeeds.
    func currentLocation(timeout: TimeInterval = 3) async throws -> Memo.Location {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw LocationError.denied
        case .notDetermined:
            // Request and wait briefly for status to update
            manager.requestWhenInUseAuthorization()
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                throw LocationError.denied
            }
        default:
            break
        }

        // Get raw CLLocation with timeout
        let clLocation = try await withTimeout(seconds: timeout) {
            try await self.fetchCLLocation()
        }

        // Reverse-geocode (also with timeout — if it fails, return coords only)
        let name = try? await withTimeout(seconds: timeout) {
            try await self.reverseGeocode(clLocation)
        }

        let result = Memo.Location(
            name: name,
            lat: clLocation.coordinate.latitude,
            lng: clLocation.coordinate.longitude
        )
        lastLocation = result
        return result
    }

    // MARK: - Private Helpers

    /// Starts a one-shot location request and waits for the first result.
    private func fetchCLLocation() async throws -> CLLocation {
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    /// Converts a CLLocation to a human-readable string via CLGeocoder.
    private func reverseGeocode(_ location: CLLocation) async throws -> String {
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        guard let placemark = placemarks.first else {
            throw LocationError.geocodingFailed
        }

        // Build a compact location string: "Name, Street" or "City" fallback
        var parts: [String] = []
        if let name = placemark.name, !name.isEmpty {
            parts.append(name)
        }
        if let thoroughfare = placemark.thoroughfare, !thoroughfare.isEmpty,
           !parts.contains(thoroughfare) {
            parts.append(thoroughfare)
        }
        if parts.isEmpty, let locality = placemark.locality {
            parts.append(locality)
        }
        if parts.isEmpty, let country = placemark.country {
            parts.append(country)
        }

        return parts.joined(separator: ", ")
    }

    /// Races a throwing async block against a timeout.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LocationError.timeout
            }
            // Return first result (or throw first error)
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.locationContinuation?.resume(returning: location)
            self.locationContinuation = nil
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.locationContinuation?.resume(throwing: error)
            self.locationContinuation = nil
        }
    }
}

// MARK: - LocationError

enum LocationError: LocalizedError {
    case denied
    case timeout
    case geocodingFailed

    var errorDescription: String? {
        switch self {
        case .denied:
            return "请在「设置 → 隐私 → 定位服务」中授权 DayPage 使用位置"
        case .timeout:
            return "位置获取超时，已记录坐标"
        case .geocodingFailed:
            return "无法解析地名"
        }
    }
}
