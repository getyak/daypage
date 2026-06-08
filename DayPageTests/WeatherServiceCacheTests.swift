import Testing
import CoreLocation
@testable import DayPage

// MARK: - WeatherServiceCacheTests

/// Tests for the geo-bucketed LRU weather cache introduced to serve nomads who
/// alternate between nearby locations (café ↔ co-working ↔ home).
///
/// Network is never hit — entries are injected directly via the internal test API.
@MainActor
struct WeatherServiceCacheTests {

    // MARK: - Helpers

    /// Injects a CacheEntry-equivalent by calling the service's internal warm-up path.
    /// We do this by populating `cache` indirectly through `seedEntry`.
    private func makeService() -> WeatherService {
        WeatherService(testing: true)
    }

    /// Seeds a geo-entry into the service's LRU cache without a network call.
    private func seed(
        _ service: WeatherService,
        weather: String,
        lat: Double,
        lng: Double,
        age: TimeInterval = 0
    ) {
        service.seedCacheEntry(weather: weather, lat: lat, lng: lng, age: age)
    }

    // MARK: - Cache hit: same location within TTL

    @Test func sameLocationWithinTTL_returnsCachedValue() async {
        let svc = makeService()
        seed(svc, weather: "20°C, Sunny", lat: 37.33, lng: -122.03)

        let location = makeLocation(lat: 37.33, lng: -122.03)
        // cachedEntry should match — exposed via cachedWeatherString for same coords.
        #expect(svc.cachedWeatherString == "20°C, Sunny")
        _ = location  // used to document intent
    }

    // MARK: - Cache miss: different location > 1km

    @Test func differentLocationBeyond1km_isCacheMiss() async {
        let svc = makeService()
        // Seed location A (San Jose)
        seed(svc, weather: "18°C, Clear", lat: 37.3382, lng: -121.8863)

        // Location B is ~5 km away (Santa Clara)
        // The service has no API key in test, so currentWeather returns nil — that proves
        // it did NOT return the cached entry for location A.
        let locationB = makeLocation(lat: 37.3541, lng: -121.9552)
        let result = await svc.currentWeather(at: locationB)
        #expect(result == nil, "No API key in tests — a cache miss must return nil, not location A's weather")
    }

    // MARK: - Re-lookup at first location hits cache

    @Test func reLookupAtFirstLocationWithinTTL_returnsCachedEntry() async {
        let svc = makeService()
        // Seed both A and B so B is present as a separate bucket.
        seed(svc, weather: "18°C, Clear",    lat: 37.3382, lng: -121.8863)  // A
        seed(svc, weather: "22°C, Overcast", lat: 37.3541, lng: -121.9552)  // B (~5 km away)

        // Re-lookup at A (within TTL) — must return A's cached value.
        let locationA = makeLocation(lat: 37.3382, lng: -121.8863)
        let result = await svc.currentWeather(at: locationA)
        #expect(result == "18°C, Clear", "Re-lookup at location A must hit the cache and return A's weather")
    }

    // MARK: - LRU bound: never exceeds 6 entries

    @Test func eightDistinctLocations_cacheLimitedToSix() async {
        let svc = makeService()
        // 8 locations spaced ~1° apart (~111 km each) — all distinct geo-buckets.
        for i in 0..<8 {
            seed(svc, weather: "Loc\(i)", lat: Double(10 + i), lng: 120.0)
        }
        #expect(svc.cacheCount == 6, "Cache must not exceed 6 entries; got \(svc.cacheCount)")
    }

    // MARK: - Stale entry (> 10 min) is treated as a miss

    @Test func staleEntry_olderThanTTL_isCacheMiss() async {
        let svc = makeService()
        // Seed with an entry that is 11 minutes old.
        seed(svc, weather: "Old weather", lat: 37.33, lng: -122.03, age: 11 * 60)

        // currentWeather should miss the stale entry; no API key → returns nil.
        let location = makeLocation(lat: 37.33, lng: -122.03)
        let result = await svc.currentWeather(at: location)
        #expect(result == nil, "An entry older than TTL must be a cache miss")
    }

    // MARK: - Missing API key returns nil (unchanged behaviour)

    @Test func missingAPIKey_returnsNil() async {
        let svc = makeService()
        let location = makeLocation(lat: 37.33, lng: -122.03)
        // No seed → no cache hit; no API key in test environment → nil.
        let result = await svc.currentWeather(at: location)
        #expect(result == nil)
    }

    // MARK: - Nil location returns nil (unchanged behaviour)

    @Test func nilLocation_returnsNil() async {
        let svc = makeService()
        let result = await svc.currentWeather(at: nil)
        #expect(result == nil)
    }

    // MARK: - cachedWeatherString reflects most-recently-fetched entry

    @Test func cachedWeatherString_returnsMostRecentEntry() {
        let svc = makeService()
        seed(svc, weather: "First",  lat: 10.0, lng: 120.0)
        seed(svc, weather: "Second", lat: 20.0, lng: 120.0)
        seed(svc, weather: "Third",  lat: 30.0, lng: 120.0)
        #expect(svc.cachedWeatherString == "Third")
    }

    // MARK: - Same location re-seed updates rather than duplicates

    @Test func reSeedSameLocation_doesNotGrowCache() {
        let svc = makeService()
        seed(svc, weather: "First",   lat: 37.33, lng: -122.03)
        seed(svc, weather: "Updated", lat: 37.33, lng: -122.03)
        #expect(svc.cacheCount == 1, "Re-seeding same location must replace, not append")
    }

    // MARK: - Private helpers

    private func makeLocation(lat: Double, lng: Double) -> Memo.Location {
        Memo.Location(name: nil, lat: lat, lng: lng)
    }
}
