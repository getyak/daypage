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

    private var cache: CacheEntry?

    /// 缓存 TTL：10 分钟
    private let cacheTTL: TimeInterval = 10 * 60

    /// 缓存条目对新位置被认为过时的最大距离（米）
    private let cacheLocationRadius: CLLocationDistance = 1000

    private init() {}

    // MARK: - Public API

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

        // 如果缓存仍然新鲜且位置足够近，返回缓存结果
        if let entry = cache,
           Date().timeIntervalSince(entry.fetchedAt) < cacheTTL {
            let cachedCoord = CLLocation(latitude: entry.lat, longitude: entry.lng)
            let requestCoord = CLLocation(latitude: lat, longitude: lng)
            if cachedCoord.distance(from: requestCoord) <= cacheLocationRadius {
                return entry.weather
            }
        }

        // 从 OpenWeatherMap 获取
        let apiKey = Secrets.resolvedOpenWeatherApiKey
        guard !apiKey.isEmpty else { return nil }

        let urlString = "https://api.openweathermap.org/data/2.5/weather?lat=\(lat)&lon=\(lng)&units=metric&lang=zh_cn&appid=\(apiKey)"
        guard let url = URL(string: urlString) else { return nil }

        let span = Secrets.sentryDSN.isEmpty ? nil
            : SentrySDK.startTransaction(name: "weather.fetch", operation: "http.client")
        defer { span?.finish() }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let formatted = try parseWeather(from: data)
            cache = CacheEntry(weather: formatted, fetchedAt: Date(), lat: lat, lng: lng)
            return formatted
        } catch {
            // 网络/解析失败不阻塞 —— 调用方在没有天气数据的情况下继续执行
            return nil
        }
    }

    // MARK: - Private Helpers

    /// 解析 OpenWeatherMap JSON 响应，格式化为 "32°C, cloudy"。
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

        // 从 "weather[0].description" 提取天气描述
        var descString = ""
        if let weatherArray = json["weather"] as? [[String: Any]],
           let first = weatherArray.first,
           let desc = first["description"] as? String {
            // 首字母大写
            descString = desc.prefix(1).uppercased() + desc.dropFirst()
        }

        let parts = [tempString, descString].filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw WeatherError.invalidResponse }
        return parts.joined(separator: ", ")
    }
}

// MARK: - WeatherError

private enum WeatherError: Error {
    case invalidResponse
}
