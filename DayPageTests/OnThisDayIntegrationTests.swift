// OnThisDayIntegrationTests.swift — Round 6 (R6-FEATURE: 时光胶囊)
//
// Validates the OnThisDay candidate + dismiss contract end-to-end:
//   - `OnThisDayIndex` picks the correct candidate (prefers 1-year-ago,
//     falls back to ~6-months-ago, then 2-years-ago) from a synthetic
//     vault seeded under VaultInitializer.testOverrideURL.
//   - `OnThisDayScheduler.markDismissedForToday()` flips the persisted
//     dismiss flag so `shouldShowToday()` returns nil for the rest of
//     the local day.
//   - The `FeatureFlag.onThisDay` kill switch toggles cleanly via
//     `FeatureFlagStore` (default-on; flip → off → on again).
//
// Why these tests: the rest of the OnThisDay surface (UI card header
// formatting) is covered by `OnThisDayHeaderTests`. These guard the
// data-side contract that downstream UI relies on.

import Testing
import Foundation
import DayPageStorage
import DayPageServices
@testable import DayPage

@MainActor
@Suite(.serialized)
struct OnThisDayIntegrationTests {

    // MARK: - Test fixture helpers

    /// Stand up a private temp vault, seed `raw/YYYY-MM-DD.md` files, and
    /// point `VaultInitializer.testOverrideURL` at it for the duration of
    /// the test. Returns the root URL so caller can clean up.
    private func seedVault(withSeeds seeds: [(date: Date, body: String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-tests-\(UUID().uuidString)", isDirectory: true)
        let rawDir = root.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current

        // Minimal YAML front-matter + body — RawStorage.parse only needs a
        // valid `---` delimiter pair and at least one memo entry.
        for seed in seeds {
            let dateStr = fmt.string(from: seed.date)
            let memoID = UUID().uuidString
            let createdStr = ISO8601DateFormatter().string(from: seed.date)
            let content = """
            ---
            id: \(memoID)
            created: \(createdStr)
            ---

            \(seed.body)
            """
            let fileURL = rawDir.appendingPathComponent("\(dateStr).md")
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        VaultInitializer.testOverrideURL = root
        return root
    }

    private func teardownVault(at root: URL) {
        VaultInitializer.testOverrideURL = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Test 1: candidate selection prefers exactly 1 year ago

    @Test func indexPicksExactlyOneYearAgo() async throws {
        // Anchor on a stable date so the test is deterministic regardless
        // of when CI runs. Use a date that doesn't fall on Feb 29.
        let cal = Calendar.current
        let today = cal.date(from: DateComponents(year: 2026, month: 6, day: 22))!
        let oneYearAgo = cal.date(byAdding: .year, value: -1, to: today)!
        let twoYearsAgo = cal.date(byAdding: .year, value: -2, to: today)!
        let unrelated = cal.date(from: DateComponents(year: 2025, month: 3, day: 15))!

        let root = try seedVault(withSeeds: [
            (oneYearAgo,    "The exact same date one year prior."),
            (twoYearsAgo,   "Same date but two years back."),
            (unrelated,     "Something unrelated from earlier this year.")
        ])
        defer { teardownVault(at: root) }

        // Reset shared singleton state so prior tests' seeded entries
        // can't pollute this candidate lookup.
        OnThisDayIndex.shared.resetForTesting()
        await OnThisDayIndex.shared.rebuildIndex()
        let entry = OnThisDayIndex.shared.candidate(for: today)

        try #require(entry != nil)
        #expect(entry!.yearsAgo == 1)
        #expect(entry!.preview.contains("one year prior"))
    }

    // MARK: - Test 2: candidate falls back to 2-years-ago when no exact-year match

    // R7: re-enabled. OnThisDayIndex now exposes a #if DEBUG `resetForTesting()`
    // hook, and this suite is @Suite(.serialized) so the singleton's in-memory
    // dict is cleared and rebuilt per test against a fresh temp vault.
    @Test func indexFallsBackToTwoYearsAgoWhenNoOneYearMatch() async throws {
        let cal = Calendar.current
        let today = cal.date(from: DateComponents(year: 2026, month: 6, day: 22))!
        let twoYearsAgo = cal.date(byAdding: .year, value: -2, to: today)!

        let root = try seedVault(withSeeds: [
            (twoYearsAgo, "From two summers ago — should still surface.")
        ])
        defer { teardownVault(at: root) }

        OnThisDayIndex.shared.resetForTesting()
        await OnThisDayIndex.shared.rebuildIndex()
        let entry = OnThisDayIndex.shared.candidate(for: today)

        try #require(entry != nil)
        #expect(entry!.yearsAgo == 2)
        #expect(entry!.preview.contains("two summers ago"))
    }

    // MARK: - Test 3: no candidate when nothing matches today's MMDD

    @Test func indexReturnsNilWhenNoMatchOnMMDD() async throws {
        let cal = Calendar.current
        let today = cal.date(from: DateComponents(year: 2026, month: 6, day: 22))!
        // Seed entries on different MMDDs only — none should match today.
        let other1 = cal.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let other2 = cal.date(from: DateComponents(year: 2024, month: 12, day: 25))!

        let root = try seedVault(withSeeds: [
            (other1, "New Year's reflection."),
            (other2, "Christmas notes.")
        ])
        defer { teardownVault(at: root) }

        OnThisDayIndex.shared.resetForTesting()
        await OnThisDayIndex.shared.rebuildIndex()
        let entry = OnThisDayIndex.shared.candidate(for: today)
        #expect(entry == nil)
    }

    // MARK: - Test 4: markDismissedForToday persists across reads

    @Test func schedulerDismissalIsPersistentForToday() async throws {
        // Reset the dismissal key so the test starts from a clean slate.
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.onThisDayDismissed)

        let scheduler = OnThisDayScheduler.shared
        #expect(scheduler.isDismissedTodayForTesting() == false)

        scheduler.markDismissedForToday()
        #expect(scheduler.isDismissedTodayForTesting() == true)

        // Cleanup so unrelated tests aren't affected.
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.onThisDayDismissed)
    }

    // MARK: - Test 5: FeatureFlag.onThisDay defaults on and toggles cleanly

    @Test func featureFlagOnThisDayDefaultsOnAndToggles() async throws {
        // Wipe any override left over from a previous run so we observe
        // the true default-state behaviour.
        UserDefaults.standard.removeObject(forKey: "ff.onThisDay")

        #expect(FeatureFlag.onThisDay.defaultEnabled == true)
        #expect(FeatureFlag.onThisDay.title == "时光胶囊")

        let store = FeatureFlagStore.shared
        // Note: FeatureFlagStore reads UserDefaults eagerly at init(); since
        // it's a singleton initialized earlier in the process, we drive the
        // toggle path here rather than asserting the pristine default state.
        store.set(.onThisDay, enabled: false)
        #expect(store.isEnabled(.onThisDay) == false)

        store.set(.onThisDay, enabled: true)
        #expect(store.isEnabled(.onThisDay) == true)

        // Cleanup so other tests see the unaltered default.
        UserDefaults.standard.removeObject(forKey: "ff.onThisDay")
    }
}
