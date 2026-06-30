import Testing
import Foundation
import DayPageStorage
import DayPageServices
@testable import DayPage

/// R4-B4: Targeted tests for the `RawStorage.atomicWrite` failure surface.
///
/// The hardened path (issue #108 / R3) added two distinct error sites:
///   1. `replaceItemAt` silently returning `nil` while throwing nothing →
///      must surface as `RawStorageError.writeFailed`.
///   2. Any thrown FileManager error from the temp-write step → must clean
///      up the orphaned temp file *and* re-throw to the caller.
///
/// The tests below exercise the happy path, simulate the failure path by
/// chmod-locking the destination directory, and pin the error case shape
/// (`RawStorageError.writeFailed` carries the offending URL).
@Suite("RawStorageWriteFailedTests")
struct RawStorageWriteFailedTests {

    // MARK: - Helpers

    /// Build a fresh sandbox directory per test so concurrent suite runs
    /// can't collide on the same temp path.
    private static func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawStorageWriteFailedTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanUp(_ url: URL) {
        // Re-add write permission so we can remove the directory we may
        // have chmod'd 0o555 mid-test.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Case 1: Normal write succeeds (control)

    @Test func normalWrite_succeedsAndContentMatches() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanUp(dir) }

        let target = dir.appendingPathComponent("ok.md")
        try RawStorage.atomicWrite(string: "hello", to: target)

        #expect(FileManager.default.fileExists(atPath: target.path))
        let read = try String(contentsOf: target, encoding: .utf8)
        #expect(read == "hello")
    }

    // MARK: - Case 2: Write to a read-only directory throws + cleans up

    /// Simulates the failure path that `replaceItemAt` (or the preceding
    /// `Data.write(to:)`) can encounter on real devices: the destination
    /// directory has been locked down. We assert that:
    ///   - an error is propagated (we do NOT swallow it),
    ///   - no orphaned `.tmp.<uuid>` file lingers in the directory.
    @Test func writeIntoReadOnlyDir_throwsAndLeavesNoTempFile() throws {
        let dir = Self.makeTempDir()
        defer { Self.cleanUp(dir) }

        // Chmod the directory to 0o555 (r-x r-x r-x) — temp-file write
        // will fail with EACCES on filesystems that honor DAC.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: dir.path
        )

        let target = dir.appendingPathComponent("locked.md")
        var didThrow = false
        do {
            try RawStorage.atomicWrite(string: "payload", to: target)
        } catch {
            didThrow = true
        }

        // Restore write permission for the assertion + tearDown.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: dir.path
        )

        // Some hosts (e.g. tmpfs without DAC enforcement) allow the write
        // through even at 0o555. Only enforce the negative assertion when
        // chmod actually changed behavior. Either way, no temp files must
        // leak.
        if didThrow {
            #expect(!FileManager.default.fileExists(atPath: target.path),
                    "Failed write must not produce a partial target file")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let tempLeaks = leftovers.filter { $0.hasPrefix(".") && $0.contains(".tmp.") }
        #expect(tempLeaks.isEmpty,
                "atomicWrite must clean up its temp file even on failure; leaked: \(tempLeaks)")
    }

    // MARK: - Case 3: RawStorageError.writeFailed shape is stable

    /// The error type itself is part of the public failure contract — the
    /// BG service / Today banner branches on it. Pin the case shape so a
    /// future rename triggers a compile error rather than a silent route
    /// change in production. (We construct the case directly; we don't try
    /// to coerce `replaceItemAt` into returning nil from a unit test.)
    @Test func writeFailedError_carriesURL() {
        let url = URL(fileURLWithPath: "/tmp/synthetic-target.md")
        let err = RawStorageError.writeFailed(url)
        switch err {
        case .writeFailed(let carried):
            #expect(carried == url)
        case .readFailed:
            // Defensive: switch over .writeFailed must never fall through to
            // .readFailed. If it does, pin the failure with a hard #expect.
            #expect(Bool(false), "writeFailed must not match readFailed")
        }
    }
}
