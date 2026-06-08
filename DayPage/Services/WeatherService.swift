import Foundation
import CoreLocation
import Sentry

// MARK: - WeatherService

/// 从 OpenWeatherMap API（免费层）获取当前天气，并缓存结果 10 分钟，
/// 避免相同位置的连续 memo 触发重复网络请求。
///
/// 用法：
///   let weather = await WeatherService.shared.currentWeather(at: location)
///
@MainActor
final class WeatherService {

    // MARK: Singleton

    static let shared = WeatherService()

    // MARK: - Cache entry

    private struct CacheEntry {
        let weather: String
        let fetchedAt: Date
        let lat: Double
        let lng: Double
    }

    // MARK: Private

    /// Bounded LRU cache: up to `cacheMaxEntries` geo-bucketed entries (most-recent last).
    private var cache: [CacheEntry] = []

    /// 缓存 TTL：10 分钟
    private let cacheTTL: TimeInterval = 10 * 60

    /// 缓存条目对新位置被认为过时的最大距离（米）
    private let cacheLocationRadius: CLLocationDistance = 1000

    /// Maximum number of distinct geo-buckets kept in memory.
    private let cacheMaxEntries = 6

    private init() {}

    // MARK: - Test Hooks

#if DEBUG
    /// Creates a fresh, isolated instance for unit tests (bypasses the singleton).
    convenience init(testing: Bool) { self.init() }

    /// Seeds a cache entry directly, bypassing network, for unit-test use only.
    func seedCacheEntry(weather: String, lat: Double, lng: Double, age: TimeInterval) {
        let fetchedAt = Date(timeIntervalSinceNow: -age)
        insertEntry(CacheEntry(weather: weather, fetchedAt: fetchedAt, lat: lat, lng: lng))
    }
#endif

    // MARK: - Public API

    /// 最近一次成功获取的天气字符串（同步，供 UI 快速读取）。
    var cachedWeatherString: String? { cache.last?.weather }

    /// Number of entries currently held in the LRU cache (test hook).
    var cacheCount: Int { cache.count }

    /// 返回给定位置的格式化天气字符串，如 "32°C, Overcast Clouds"。
    ///
    /// - Returns: 本地化的天气字符串；如果 API 密钥缺失、网络不可用或调用因任何原因失败，则返回 `nil`。
    ///            调用方不得阻塞此方法 —— 从提交流程中调用时采用即发即忘模式。
    func currentWeather(at location: Memo.Location?) async -> String? {
        guard let location,
              let lat = location.lat,
              let lng = location.lng else {
            return nil
        }

        // Return a fresh, nearby cached entry if one exists.
        if let entry = cachedEntry(for: CLLocation(latitude: lat, longitude: lng)) {
            return entry.weather
        }

        // 从 OpenWeatherMap 获取
        let apiKey = Secrets.resolvedOpenWeatherApiKey
        guard !apiKey.isEmpty else { return nil }

        // URLComponents avoids string-interpolating the API key and handles percent-encoding.
        guard var components = URLComponents(string: "https://api.openweathermap.org/data/2.5/weather") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "lat",   value: String(lat)),
            URLQueryItem(name: "lon",   value: String(lng)),
            URLQueryItem(name: "units", value: "metric"),
            URLQueryItem(name: "lang",  value: "zh_cn"),
            URLQueryItem(name: "appid", value: apiKey),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10  // weather is non-critical; don't stall memo saves

        let span = Secrets.sentryDSN.isEmpty ? nil
            : SentrySDK.startTransaction(name: "weather.fetch", operation: "http.client")
        defer { span?.finish() }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let formatted = try parseWeather(from: data)
            insertEntry(CacheEntry(weather: formatted, fetchedAt: Date(), lat: lat, lng: lng))
            return formatted
        } catch {
            // 网络/解析失败不阻塞 —— 调用方在没有天气数据的情况下继续执行
            return nil
        }
    }

    // MARK: - Cache Helpers

    /// Returns the first fresh entry whose location is within `cacheLocationRadius` of `coord`.
    private func cachedEntry(for coord: CLLocation) -> CacheEntry? {
        cache.first { entry in
            guard Date().timeIntervalSince(entry.fetchedAt) < cacheTTL else { return false }
            let entryCoord = CLLocation(latitude: entry.lat, longitude: entry.lng)
            return entryCoord.distance(from: coord) <= cacheLocationRadius
        }
    }

    /// Inserts `entry`, pruning any stale same-location entry first, then trims to `cacheMaxEntries`.
    private func insertEntry(_ entry: CacheEntry) {
        let coord = CLLocation(latitude: entry.lat, longitude: entry.lng)
        // Remove any existing (possibly stale) entry for the same geo-bucket.
        cache.removeAll { existing in
            let existingCoord = CLLocation(latitude: existing.lat, longitude: existing.lng)
            return existingCoord.distance(from: coord) <= cacheLocationRadius
        }
        cache.append(entry)
        // Trim oldest entries beyond the max capacity.
        if cache.count > cacheMaxEntries {
            cache.removeFirst(cache.count - cacheMaxEntries)
        }
    }

    // MARK: - Private Helpers

    /// 解析 OpenWeatherMap JSON 响应，格式化为 "☁️ 32°C, cloudy"。
    private func parseWeather(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WeatherError.invalidResponse
        }

        // 从 "main.temp" 提取温度
        var tempString = ""
        if let main = json["main"] as? [String: Any],
           let temp = main["temp"] as? Double {
            let rounded = Int(temp.rounded())
            tempString = "\(rounded)\u{00B0}C"   // e.g. "32°C"
        }

        // 从 "weather[0]" 提取描述、condition code 和 icon
        var descString = ""
        var conditionGlyph: String? = nil
        if let weatherArray = json["weather"] as? [[String: Any]],
           let first = weatherArray.first {
            if let desc = first["description"] as? String {
                // 首字母大写
                descString = desc.prefix(1).uppercased() + desc.dropFirst()
            }
            if let code = first["id"] as? Int {
                let icon = first["icon"] as? String
                conditionGlyph = WeatherService.glyph(forConditionCode: code, icon: icon)
            }
        }

        let parts = [tempString, descString].filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw WeatherError.invalidResponse }
        let base = parts.joined(separator: ", ")
        if let glyph = conditionGlyph {
            return glyph + "\u{2009}" + base
        }
        return base
    }

    /// Maps an OpenWeatherMap condition code (and optional icon string for day/night) to an emoji glyph.
    static func glyph(forConditionCode code: Int, icon: String?) -> String {
        switch code {
        case 200...299: return "⛈"
        case 300...399: return "🌦"
        case 500...599: return "🌧"
        case 600...699: return "❄️"
        case 700...799: return "🌫"
        case 800:
            let isNight = icon?.hasSuffix("n") == true
            return isNight ? "🌙" : "☀️"
        case 801...809: return "☁️"
        default:        return "🌤"
        }
    }
}

// MARK: - WeatherError

private enum WeatherError: Error {
    case invalidResponse
}
