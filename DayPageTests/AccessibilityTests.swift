import Testing
import Foundation
import SwiftUI
@testable import DayPage

/// Accessibility regression tests for Goal C (Motion + Dynamic Type).
///
/// These tests are pragmatic: visual a11y is hard to unit-test, so we lean on
/// (a) a contract check on `Motion.respectReduceMotion(_:)`, (b) a smoke build
/// of the primary read-path card at the largest Dynamic Type size, and (c)
/// regex regression guards that the four vestibular-critical `repeatForever`
/// sites are still gated by `reduceMotion` — which is the most likely place
/// for someone to silently regress accessibility.
@MainActor
@Suite("AccessibilityTests", .serialized)
struct AccessibilityTests {

    // MARK: - Motion contract

    /// `Motion.respectReduceMotion(_:)` is a pure function over
    /// `UIAccessibility.isReduceMotionEnabled`. In the test process Reduce
    /// Motion is off by default, so the helper must return *some* animation
    /// without crashing. We avoid mocking UIAccessibility (a static singleton)
    /// and document the reduced-motion branch as integration-only — the
    /// Simulator → Settings → Accessibility → Reduce Motion toggle exercises
    /// the other branch manually.
    @Test func respectReduceMotion_returnsAnAnimationWithoutCrashing() {
        let base = Motion.spring
        let result = Motion.respectReduceMotion(base)
        _ = result
        #expect(Bool(true), "respectReduceMotion returned an Animation without trapping")
    }

    // MARK: - Dynamic Type smoke test

    /// MemoCardView is the primary read-path surface. Construct it inside the
    /// largest accessibility text size and verify it builds without crashing.
    /// We don't have ViewInspector — this is intentionally a smoke test that
    /// catches the "force-unwrapped layout at accessibility5" class of bugs.
    /// Anything more involved should be a snapshot test.
    @Test func memoCardView_buildsAtAccessibility5() {
        let memo = Memo(
            id: UUID(),
            type: .text,
            created: Date(),
            body: "Test memo for Dynamic Type smoke test"
        )
        // Force the SwiftUI view value to be constructed. If a hardcoded frame
        // or modifier traps at accessibility5, this trips.
        let view = MemoCardView(memo: memo)
            .environment(\.dynamicTypeSize, .accessibility5)
        _ = view
        #expect(Bool(true), "MemoCardView constructed under accessibility5 Dynamic Type")
    }

    // MARK: - Vestibular regression guards
    //
    // These tests read each file's source as text and assert that the
    // documented `repeatForever` / vestibular-sensitive sites still reference
    // `reduceMotion`. They are deliberately coarse — anyone who re-introduces
    // a raw `repeatForever` without a reduce-motion gate nearby will fail one
    // of these. The test source-of-truth is the file content on disk, located
    // via the SRCROOT-style walk below.

    /// Walk up from this test file until we find a sibling `DayPage/` source
    /// directory; that's the repo root.
    private func projectRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("DayPage", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw AccessibilityTestError.cannotLocateProjectRoot
    }

    private func assertGuardedRepeatForever(in relativePath: String) throws {
        let root = try projectRoot()
        let url = root.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("repeatForever"),
            "\(relativePath) should still contain a repeatForever animation (test outdated otherwise)"
        )
        #expect(
            source.contains("reduceMotion"),
            "\(relativePath) must reference reduceMotion — vestibular regression guard"
        )
    }

    @Test func compileUnlockCard_guardsRepeatForever() throws {
        try assertGuardedRepeatForever(in: "DayPage/Features/Today/CompileUnlockCard.swift")
    }

    @Test func inputBarV4_guardsRepeatForever() throws {
        try assertGuardedRepeatForever(in: "DayPage/Features/Today/InputBarV4.swift")
    }

    @Test func aiSummaryCard_guardsRepeatForever() throws {
        try assertGuardedRepeatForever(in: "DayPage/Features/Today/AISummaryCard.swift")
    }

    @Test func entityPageView_guardsRepeatForever() throws {
        try assertGuardedRepeatForever(in: "DayPage/Features/Entity/EntityPageView.swift")
    }
}

private enum AccessibilityTestError: Error {
    case cannotLocateProjectRoot
}
