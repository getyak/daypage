import Foundation
import CoreLocation

// MARK: - LocationService

/// 包装 CLLocationManager，提供简单的异步 API：
///   1. 请求"使用期间"位置权限
///   2. 获取当前 GPS 坐标（单次）
///   3. 将坐标反向地理编码为人类可读的地名
///
/// 用法：
///   let loc = try await LocationService.shared.currentLocation(timeout: 3)
///
@MainActor
final class LocationService: NSObject, ObservableObject {

    // MARK: Singleton

    static let shared = LocationService()

    // MARK: Published

    /// 当前授权状态；UI 可以监听此值来显示权限提示。
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// 最近解析的位置结果（名称 + 坐标）。
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

    /// 如果尚未确定，请求"使用期间"授权。
    /// 在调用 `currentLocation()` 之前从主线程调用。
    func requestPermissionIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    /// 请求"始终"授权以进行后台被动位置监控。
    /// 需要 Info.plist 中的 NSLocationAlwaysAndWhenInUseUsageDescription。
    func requestAlwaysAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// 应用是否具有"始终"位置授权。
    var hasAlwaysAuthorization: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    /// 获取当前 GPS 位置并将其反向地理编码为 `Memo.Location`。
    ///
    /// - Parameter timeout: 在退回到仅坐标之前等待的秒数（默认 3 秒）。
    /// - Throws: 如果权限被拒绝/受限，抛出 `LocationError.denied`。
    /// - Returns: 一个 `Memo.Location`，其中 `lat`/`lng` 总是设置的；当地理编码成功时设置 `name`。
    func currentLocation(timeout: TimeInterval = 3) async throws -> Memo.Location {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw LocationError.denied
        case .notDetermined:
            // 请求并短暂等待状态更新
            manager.requestWhenInUseAuthorization()
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                throw LocationError.denied
            }
        default:
            break
        }

        // 获取原始 CLLocation，带超时
        let clLocation = try await withTimeout(seconds: timeout) {
            try await self.fetchCLLocation()
        }

        // 反向地理编码（也带超时 — 如果失败，仅返回坐标）
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

    /// 发起单次位置请求并等待第一个结果。
    private func fetchCLLocation() async throws -> CLLocation {
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    /// 通过 CLGeocoder 将 CLLocation 转换为人类可读的字符串。
    private func reverseGeocode(_ location: CLLocation) async throws -> String {
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        guard let placemark = placemarks.first else {
            throw LocationError.geocodingFailed
        }

        // 构建紧凑的位置字符串："名称, 街道" 或回退到"城市"
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

    /// 将一个可能抛出错误的异步操作与超时进行竞速。
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
            // 返回第一个结果（或抛出第一个错误）
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
