import Testing
@testable import DayPage

@Suite("HapticFeedback")
@MainActor
struct HapticFeedbackTests {

    @Test func lightIsCallable() {
        HapticFeedback.light()
    }

    @Test func mediumIsCallable() {
        HapticFeedback.medium()
    }

    @Test func heavyIsCallable() {
        HapticFeedback.heavy()
    }

    @Test func successIsCallable() {
        HapticFeedback.success()
    }

    @Test func warningIsCallable() {
        HapticFeedback.warning()
    }

    @Test func errorIsCallable() {
        HapticFeedback.error()
    }
}
