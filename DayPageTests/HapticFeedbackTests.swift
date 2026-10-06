import Testing
@testable import DayPage

extension DayPageSerialSwiftTests {
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
}


// MARK: - DayPageSerialSwiftTests namespace aliases (preserve global names for helpers,
// extensions, and qualified references after the serialized-root move)
typealias HapticFeedbackTests = DayPageSerialSwiftTests.HapticFeedbackTests
