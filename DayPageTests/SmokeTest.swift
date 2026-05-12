import Testing

/// Minimal smoke test — confirms the DayPageTests target compiles and Swift Testing runs.
@Suite("Smoke")
struct SmokeTest {
    @Test func alwaysPasses() {
        #expect(true == true)
    }
}
