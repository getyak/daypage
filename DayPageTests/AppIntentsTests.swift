import Testing
import Foundation
@testable import DayPage

// MARK: - AppIntentsTests
//
// Unit tests for the new AppIntents URL contracts + AppNavigationModel deep-link
// state plumbing. Stays out of UIApplication/Simulator territory by exercising
// the static `buildURL(...)` helpers and the in-memory @Published properties.
//
// Coverage:
//   • URL encoding for QuickCaptureTextIntent, AskTodayIntent, OpenDailyPageIntent
//   • OpenDailyPageIntent.formattedDate honors the supplied TimeZone
//   • AppNavigationModel.openArchive sets pendingArchiveDate + switches tab
//   • pendingSearchQuery as a one-shot ObservableObject hand-off

@MainActor
@Suite("AppIntentsTests", .serialized)
struct AppIntentsTests {

    // MARK: - QuickCaptureTextIntent URL contract

    @Test func quickCaptureText_buildsExpectedURL() throws {
        let url = try #require(QuickCaptureTextIntent.buildURL(text: "hello world"))
        #expect(url.scheme == "daypage")
        #expect(url.host == "memo")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let text = components.queryItems?.first(where: { $0.name == "text" })?.value
        #expect(text == "hello world")
    }

    @Test func quickCaptureText_encodesSpecialCharacters() throws {
        // Chinese + symbols must survive a round-trip through URLComponents.
        let original = "今天 & 明天 = 好天气?"
        let url = try #require(QuickCaptureTextIntent.buildURL(text: original))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let decoded = components.queryItems?.first(where: { $0.name == "text" })?.value
        #expect(decoded == original)
    }

    // MARK: - AskTodayIntent URL contract

    @Test func askToday_buildsSearchURL() throws {
        let url = try #require(AskTodayIntent.buildURL(query: "weekend plans"))
        #expect(url.scheme == "daypage")
        #expect(url.host == "search")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let q = components.queryItems?.first(where: { $0.name == "q" })?.value
        #expect(q == "weekend plans")
    }

    // MARK: - OpenDailyPageIntent date formatting

    @Test func openDailyPage_formattedDateUsesSuppliedTimeZone() {
        // 2025-06-17 00:30 UTC is still 2025-06-16 in PDT (UTC-7 during DST).
        // The vault filename should follow the supplied time zone.
        var components = DateComponents()
        components.year = 2025
        components.month = 6
        components.day = 17
        components.hour = 0
        components.minute = 30
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!

        let utc = OpenDailyPageIntent.formattedDate(date, timeZone: TimeZone(identifier: "UTC")!)
        let la = OpenDailyPageIntent.formattedDate(date, timeZone: TimeZone(identifier: "America/Los_Angeles")!)

        #expect(utc == "2025-06-17")
        #expect(la == "2025-06-16")
    }

    @Test func openDailyPage_buildsDailyURL() throws {
        let url = try #require(OpenDailyPageIntent.buildURL(dateString: "2025-06-17"))
        #expect(url.scheme == "daypage")
        #expect(url.host == "daily")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let date = components.queryItems?.first(where: { $0.name == "date" })?.value
        #expect(date == "2025-06-17")
    }

    // MARK: - AppNavigationModel deep-link state

    @Test func openArchive_setsPendingDateAndSwitchesTab() {
        let nav = AppNavigationModel()
        nav.selectedTab = .today

        nav.openArchive(at: "2025-06-17")

        #expect(nav.pendingArchiveDate == "2025-06-17")
        #expect(nav.selectedTab == .archive)
    }

    @Test func pendingSearchQuery_isOneShotHandoff() {
        let nav = AppNavigationModel()
        #expect(nav.pendingSearchQuery == nil)

        // Simulate `DayPageApp.onOpenURL` stashing a query …
        nav.pendingSearchQuery = "weekend plans"
        #expect(nav.pendingSearchQuery == "weekend plans")

        // … ArchiveView's consume step clears it so re-firing the same
        // shortcut re-triggers the change observer.
        nav.pendingSearchQuery = nil
        #expect(nav.pendingSearchQuery == nil)
    }
}
