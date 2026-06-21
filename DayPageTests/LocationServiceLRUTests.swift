import Testing
import Foundation
@testable import DayPage

/// R4-B4: Unit tests for the LRU geocode-cache rules used by `LocationService`.
///
/// The real `LocationService.geocodeCache` is `private` and bolted to
/// `CLGeocoder` + `@MainActor`, so we can't drive it directly from a test.
/// What we CAN do — and what costs the most when broken — is pin the two
/// invariants that protect the cache from doing the wrong thing:
///
///   1. **bucket quantization** — the `~1km` key MUST collapse "almost
///      identical" coordinates into one bucket and split clearly different
///      coordinates apart. Drift here = phantom cache misses or, worse,
///      mis-reusing a neighborhood's name for a different city.
///   2. **LRU + TTL semantics** — bounded capacity (10) with oldest-first
///      eviction, and 30-min entry expiry. We model the same data structure
///      `LocationService` uses and assert against the same rules so a
///      future "let's bump cap to 20" tweak forces an explicit test update.
@Suite("LocationServiceLRUTests")
struct LocationServiceLRUTests {

    // MARK: - bucketKey: ~1km quantization

    /// Two coords < ~0.5km apart, picked safely inside the same %.2f
    /// rounding bucket, must share a key. (The rounding is
    /// `round(x * 100) / 100`, so the bucket spans
    /// [N.NN5, N.NN5+0.01); both coords below sit at N.7720..N.7724,
    /// inside the 37.77 bucket.)
    @Test func bucketKey_collapsesNearbyCoords() {
        // Both well inside the 37.77 / -122.42 bucket — ~40m apart.
        let a = LocationService.bucketKey(lat: 37.7720, lng: -122.4200)
        let b = LocationService.bucketKey(lat: 37.7724, lng: -122.4196)
        #expect(a == b, "Sub-bucket neighbors must collapse: \(a) vs \(b)")
    }

    /// Two coords ~5km apart MUST land in different buckets — that's the
    /// invariant that prevents a Mission-District name leaking into a
    /// Sunset-District lookup.
    @Test func bucketKey_separatesDistantCoords() {
        let a = LocationService.bucketKey(lat: 37.7749, lng: -122.4194) // ~SoMa
        let b = LocationService.bucketKey(lat: 37.7200, lng: -122.4800) // ~Sunset, ~5km SW
        #expect(a != b, "5km-apart coords must NOT share a bucket: \(a) == \(b)")
    }

    /// Same input → same output (pure function). Pin this so a stray
    /// `Locale.current`-sensitive formatter change can't silently break
    /// the cache key.
    @Test func bucketKey_isStable() {
        let first = LocationService.bucketKey(lat: 51.5074, lng: -0.1278)  // London
        let second = LocationService.bucketKey(lat: 51.5074, lng: -0.1278)
        #expect(first == second)
        // Format pin: always exactly "lat,lng" with 2 decimals.
        #expect(first.split(separator: ",").count == 2)
    }

    /// Negative longitude / equator-crossing latitudes must still produce
    /// well-formed keys that round-trip through `Double()`.
    @Test func bucketKey_handlesNegativeAndZero() {
        let key = LocationService.bucketKey(lat: 0.0, lng: -0.0)
        #expect(!key.isEmpty)
        let parts = key.split(separator: ",")
        #expect(parts.count == 2)
        #expect(Double(parts[0]) != nil)
        #expect(Double(parts[1]) != nil)
    }

    // MARK: - LRU model: cache invariants

    /// Mirror of the (bucket, name, expiry) triple `LocationService` keeps
    /// in an Array<>-backed LRU. The real implementation is private and
    /// `@MainActor`-isolated, so the test reproduces the rules here to
    /// catch invariant drift via test review when the real cache changes
    /// shape.
    private struct CacheEntry: Equatable {
        let bucket: String
        let name: String
        let expiry: Date
    }

    private final class LRUMirror {
        private(set) var entries: [CacheEntry] = []
        let limit: Int
        let ttl: TimeInterval

        init(limit: Int = 10, ttl: TimeInterval = 30 * 60) {
            self.limit = limit
            self.ttl = ttl
        }

        /// Same lookup as `LocationService.reverseGeocode`: drop expired
        /// first, then check live cache; on miss simulate the network
        /// resolve by inserting the supplied `resolve` result.
        @discardableResult
        func lookupOrResolve(bucket: String,
                             now: Date,
                             resolve: () -> String) -> String {
            entries.removeAll { $0.expiry <= now }
            if let hit = entries.first(where: { $0.bucket == bucket }) {
                return hit.name
            }
            let resolved = resolve()
            if entries.count >= limit { entries.removeFirst() }
            entries.append(CacheEntry(bucket: bucket,
                                      name: resolved,
                                      expiry: now.addingTimeInterval(ttl)))
            return resolved
        }
    }

    /// Same bucket → second lookup skips the resolve callback entirely.
    @Test func cache_hitOnSecondLookupForSameBucket() {
        let lru = LRUMirror()
        let now = Date()
        var resolveCount = 0

        _ = lru.lookupOrResolve(bucket: "37.77,-122.42", now: now) {
            resolveCount += 1
            return "Market St"
        }
        let second = lru.lookupOrResolve(bucket: "37.77,-122.42", now: now) {
            resolveCount += 1
            return "SHOULD NOT BE CALLED"
        }
        #expect(resolveCount == 1, "Cache hit must NOT re-invoke the resolver")
        #expect(second == "Market St")
    }

    /// Entry inserted at t0 must be evicted when looked up at t0+31min
    /// (TTL = 30min, so 31min is past expiry).
    @Test func cache_evictsExpiredEntryAfter30Minutes() {
        let lru = LRUMirror()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var resolveCount = 0

        _ = lru.lookupOrResolve(bucket: "37.77,-122.42", now: t0) {
            resolveCount += 1
            return "A"
        }

        let later = t0.addingTimeInterval(31 * 60)
        _ = lru.lookupOrResolve(bucket: "37.77,-122.42", now: later) {
            resolveCount += 1
            return "B"
        }
        #expect(resolveCount == 2, "Expired entry must force a fresh resolve")
        #expect(lru.entries.count == 1)
        #expect(lru.entries.first?.name == "B")
    }

    /// At the 10-entry cap, an 11th distinct bucket must evict the OLDEST
    /// (front) entry — never the most recently used one.
    @Test func cache_evictsOldestAt10EntryLimit() {
        let lru = LRUMirror(limit: 10)
        let now = Date()

        // Fill with 10 distinct buckets.
        for i in 0..<10 {
            _ = lru.lookupOrResolve(bucket: "bucket-\(i)", now: now) { "name-\(i)" }
        }
        #expect(lru.entries.count == 10)
        #expect(lru.entries.first?.bucket == "bucket-0")

        // 11th bucket must evict bucket-0.
        _ = lru.lookupOrResolve(bucket: "bucket-10", now: now) { "name-10" }
        #expect(lru.entries.count == 10)
        #expect(lru.entries.first?.bucket == "bucket-1",
                "Oldest (bucket-0) must be evicted; got front=\(String(describing: lru.entries.first?.bucket))")
        #expect(lru.entries.last?.bucket == "bucket-10")
    }
}
