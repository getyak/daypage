import Testing

/// Shared serialized root for every Swift Testing suite in `DayPageTests`.
///
/// All suite types are nested under this root (directly in this file or via
/// `extension DayPageSerialSwiftTests` in their own files) so the single
/// `.serialized` trait serializes every Swift Testing case in the target
/// across files. Per-suite `.serialized` only serializes within one suite,
/// and `@MainActor` can re-enter at `await`; this root is the only construct
/// proven to serialize peers (see docs/engineering/ios-five-pass.md).
@Suite("DayPageSerialSwiftTests", .serialized)
struct DayPageSerialSwiftTests {
}

extension DayPageSerialSwiftTests {
/// Minimal smoke test — confirms the DayPageTests target compiles and Swift Testing runs.
@Suite("Smoke")
struct SmokeTest {
    @Test func alwaysPasses() {
        #expect(true == true)
    }
}
}


// MARK: - DayPageSerialSwiftTests namespace aliases (preserve global names for helpers,
// extensions, and qualified references after the serialized-root move)
typealias SmokeTest = DayPageSerialSwiftTests.SmokeTest
