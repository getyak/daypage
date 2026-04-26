import Foundation
import CoreLocation
import Sentry

// MARK: - WeatherService

/// Fetches current weather from OpenWeatherMap API (free tier) and caches
/// the result for 10 minutes so consecutive memos at the same location
/// don't trigger repeated network calls.
///
/// Usage:
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

    /// Cache TTL: 10 minutes
    private let cacheTTL: TimeInterval = 10 * 60

    /// Maximum distance (metres) before the cached entry is considered stale for the new location.
    private let cacheLocationRadius: CLLocationDistance = 1000

    private init() {}

    // MARK: - Public API

    /// Returns a formatted weather string like "32°C, Overcast Clouds" for the given location.
    ///
    /// - Returns: A localised weather string, or `nil` if the API key is missing,
    ///            the network is unavailable, or the call fails for any reason.
    ///            Callers must NOT block on this — it is fire-and-forget from the
    ///            submission path.
    func currentWeather(at location: Memo.Location?) async -> String? {
        guard let location,
              let lat = location.lat,
              let lng = location.lng else {
            return nil
        }

        // Return cached result if still fresh and close enough
        if let entry = cache,
           Date().timeIntervalSince(entry.fetchedAt) < cacheTTL {
            let cachedCoord = CLLocation(latitude: entry.lat, longitude: entry.lng)
            let requestCoord = CLLocation(latitude: lat, longitude: lng)
            if cachedCoord.distance(from: requestCoord) <= cacheLocationRadius {
                return entry.weather
            }
        }

        // Fetch from OpenWeatherMap
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
            // Network/parse failure is non-blocking — caller continues without weather
            return nil
        }
    }

    // MARK: - Private Helpers

    /// Parses the OpenWeatherMap JSON response and formats it as "32°C, cloudy".
    private func parseWeather(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WeatherError.invalidResponse
        }

        // Extract temperature from "main.temp"
        var tempString = ""
        if let main = json["main"] as? [String: Any],
           let temp = main["temp"] as? Double {
            let rounded = Int(temp.rounded())
            tempString = "\(rounded)\u{00B0}C"   // e.g. "32°C"
        }

        // Extract weather description from "weather[0].description"
        var descString = ""
        if let weatherArray = json["weather"] as? [[String: Any]],
           let first = weatherArray.first,
           let desc = first["description"] as? String {
            // Capitalise first character
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
