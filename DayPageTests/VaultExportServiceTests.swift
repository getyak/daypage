// VaultExportServiceTests.swift — R11-MEDIUM (#101)
//
// Covers VaultExportService.computeManifest(vaultURL:) — the pure helper
// path. We deliberately do NOT exercise collectExportManifest() / the
// singleton: that would couple every test run to VaultInitializer.shared
// state, and the @MainActor async wrapper adds no logic beyond "rethrow as
// .vaultNotFound / .noData", which is trivial.
//
// Each test seeds a fresh tmpdir vault, runs the helper, asserts, then
// removes the tmpdir in defer. Suite is .serialized because FileManager
// operations are global state.

import Testing
import Foundation
@testable import DayPage

@MainActor
@Suite(.serialized)
struct VaultExportServiceTests {

    // MARK: - Fixture helpers

    /// Spin up an empty tmpdir to act as the vault root. Caller is
    /// responsible for `try? FileManager.default.removeItem(at:)` in `defer`.
    private func makeVaultRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Seed a vault with the requested number of files under each
    /// subdirectory. Returns the root URL. All `.md` files share the same
    /// dummy YAML-front-matter + body so byte-size assertions are predictable.
    private func seedVault(
        raw: Int = 0,
        daily: Int = 0,
        places: Int = 0,
        people: Int = 0,
        themes: Int = 0,
        assets: Int = 0
    ) throws -> URL {
        let root = try makeVaultRoot()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("wiki/daily"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("wiki/places"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("wiki/people"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("wiki/themes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("raw/assets"), withIntermediateDirectories: true)

        // Dummy markdown — fixed bytes so the byte-sum test stays deterministic.
        let mdBody = "---\nid: dummy\n---\nbody"
        for i in 0..<raw {
            try mdBody.write(
                to: root.appendingPathComponent("raw/2026-06-\(String(format: "%02d", i+1)).md"),
                atomically: true, encoding: .utf8
            )
        }
        for i in 0..<daily {
            try mdBody.write(
                to: root.appendingPathComponent("wiki/daily/2026-06-\(String(format: "%02d", i+1)).md"),
                atomically: true, encoding: .utf8
            )
        }
        for i in 0..<places {
            try mdBody.write(
                to: root.appendingPathComponent("wiki/places/place-\(i).md"),
                atomically: true, encoding: .utf8
            )
        }
        for i in 0..<people {
            try mdBody.write(
                to: root.appendingPathComponent("wiki/people/person-\(i).md"),
                atomically: true, encoding: .utf8
            )
        }
        for i in 0..<themes {
            try mdBody.write(
                to: root.appendingPathComponent("wiki/themes/theme-\(i).md"),
                atomically: true, encoding: .utf8
            )
        }
        // PNG magic-byte stub — 4 bytes per file makes asset byte math easy.
        for i in 0..<assets {
            try Data([0x89, 0x50, 0x4E, 0x47]).write(
                to: root.appendingPathComponent("raw/assets/img-\(i).png")
            )
        }
        return root
    }

    // MARK: - Tests

    /// 3 raw + 2 daily + 1 place + 1 person + 1 theme + 2 assets. Verifies
    /// rawMemoCount / dailyPageCount / assetCount land in the right buckets,
    /// and entityCount = places + people + themes (1+1+1).
    @Test func computeManifest_countsAllSubdirectories() throws {
        let root = try seedVault(raw: 3, daily: 2, places: 1, people: 1, themes: 1, assets: 2)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try VaultExportService.computeManifest(vaultURL: root)

        #expect(manifest != nil)
        #expect(manifest?.rawMemoCount == 3)
        #expect(manifest?.dailyPageCount == 2)
        #expect(manifest?.entityCount == 3) // 1 place + 1 person + 1 theme
        #expect(manifest?.assetCount == 2)
        #expect((manifest?.estimatedTotalBytes ?? 0) > 0)
    }

    /// Vault root exists but every subdirectory is empty.
    /// computeManifest() returns a populated-but-all-zero ExportManifest —
    /// translating that into .noData is the @MainActor wrapper's job, not
    /// the pure helper's.
    @Test func computeManifest_returnsZerosForEmptySubdirectories() throws {
        let root = try seedVault() // all zero
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try VaultExportService.computeManifest(vaultURL: root)

        #expect(manifest != nil)
        #expect(manifest?.rawMemoCount == 0)
        #expect(manifest?.dailyPageCount == 0)
        #expect(manifest?.entityCount == 0)
        #expect(manifest?.assetCount == 0)
        #expect(manifest?.estimatedTotalBytes == 0)
        // Sanity-check the shared emptiness predicate so the wrapper can rely on it.
        if let m = manifest {
            #expect(VaultExportService.isEmpty(m))
        }
    }

    /// Assets must be counted recursively — assets/photos/foo.jpg and
    /// assets/audio/bar.m4a both contribute. Catches regressions where a
    /// future refactor swaps enumerator() back to contentsOfDirectory().
    @Test func computeManifest_handlesNestedAssetsRecursively() throws {
        let root = try seedVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let assetsDir = root.appendingPathComponent("raw/assets")
        try fm.createDirectory(at: assetsDir.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try fm.createDirectory(at: assetsDir.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: assetsDir.appendingPathComponent("photos/foo.jpg"))
        try Data([0x00, 0x00, 0x00, 0x20]).write(to: assetsDir.appendingPathComponent("audio/bar.m4a"))

        let manifest = try VaultExportService.computeManifest(vaultURL: root)

        #expect(manifest?.assetCount == 2)
        // 4 + 4 = 8 bytes from the two binary stubs.
        #expect(manifest?.estimatedTotalBytes == 8)
    }

    /// Byte total must sum across every subdirectory, not just one bucket.
    /// We write fixed-content files to each subdirectory and assert the total
    /// equals the sum of each file's byte count.
    @Test func computeManifest_sumsBytesAcrossSubdirectories() throws {
        let root = try seedVault()
        defer { try? FileManager.default.removeItem(at: root) }

        // Known byte sizes per file.
        let rawContent   = "raw-12"          // 6 bytes UTF-8
        let dailyContent = "daily"           // 5 bytes
        let placeContent = "place"           // 5 bytes
        let assetBytes   = Data([0x01, 0x02, 0x03]) // 3 bytes

        try rawContent.write(
            to: root.appendingPathComponent("raw/r.md"),
            atomically: true, encoding: .utf8
        )
        try dailyContent.write(
            to: root.appendingPathComponent("wiki/daily/d.md"),
            atomically: true, encoding: .utf8
        )
        try placeContent.write(
            to: root.appendingPathComponent("wiki/places/p.md"),
            atomically: true, encoding: .utf8
        )
        try assetBytes.write(to: root.appendingPathComponent("raw/assets/a.bin"))

        let manifest = try VaultExportService.computeManifest(vaultURL: root)

        let expected: Int64 = Int64(rawContent.utf8.count)
                            + Int64(dailyContent.utf8.count)
                            + Int64(placeContent.utf8.count)
                            + Int64(assetBytes.count)
        #expect(manifest?.estimatedTotalBytes == expected)
    }

    /// Vault root itself missing -> helper returns nil (the @MainActor
    /// wrapper translates that into .vaultNotFound). Included so future
    /// refactors can't silently swap nil for a zero-count manifest, which
    /// would defeat the .vaultNotFound vs .noData distinction.
    @Test func computeManifest_returnsNilWhenVaultMissing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-export-tests-missing-\(UUID().uuidString)")
        // Deliberately do NOT create the directory.
        let manifest = try VaultExportService.computeManifest(vaultURL: missing)
        #expect(manifest == nil)
    }

    // MARK: - R13 zip packaging tests

    /// Happy path. Seed a small fixture vault, ask for `.all`, assert a
    /// non-empty zip lands at the returned URL. Doesn't try to validate the
    /// zip's internal structure — that's the OS's responsibility; we only
    /// care that NSFileCoordinator actually produced an archive.
    @Test func exportVaultZip_producesNonEmptyZipFile() async throws {
        let root = try seedVault(raw: 2, daily: 1, places: 1, assets: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        VaultInitializer.testOverrideURL = root
        defer { VaultInitializer.testOverrideURL = nil }

        let zipURL = try await VaultExportService.shared.exportVaultZip(includes: .all)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        #expect(FileManager.default.fileExists(atPath: zipURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        #expect(size > 0)
    }

    /// Empty vault -> .noData. Matches the manifest path's contract so
    /// callers see one well-defined error class for "nothing to export yet".
    @Test func exportVaultZip_throwsNoDataForEmptyVault() async throws {
        let root = try seedVault() // all zero
        defer { try? FileManager.default.removeItem(at: root) }

        VaultInitializer.testOverrideURL = root
        defer { VaultInitializer.testOverrideURL = nil }

        var caught: VaultExportError?
        do {
            _ = try await VaultExportService.shared.exportVaultZip(includes: .all)
        } catch let e as VaultExportError {
            caught = e
        }
        #expect(caught == .noData)
    }

    /// `[]` (empty OptionSet) is rejected up front with .exportFailed —
    /// guards against silently producing a zip that only contains an
    /// empty staging directory.
    @Test func exportVaultZip_throwsExportFailedForEmptyIncludes() async throws {
        let root = try seedVault(raw: 2)
        defer { try? FileManager.default.removeItem(at: root) }

        VaultInitializer.testOverrideURL = root
        defer { VaultInitializer.testOverrideURL = nil }

        var caught: VaultExportError?
        do {
            _ = try await VaultExportService.shared.exportVaultZip(includes: [])
        } catch let e as VaultExportError {
            caught = e
        }
        // Pattern-match the associated value so the assertion focuses on
        // intent ("contains 'no subdirectories'") rather than the exact
        // wording, which can drift across rounds.
        if case let .exportFailed(reason) = caught {
            #expect(reason.contains("no subdirectories"))
        } else {
            Issue.record("expected .exportFailed, got \(String(describing: caught))")
        }
    }

    /// Progress reaches 1.0. We don't assert every milestone — that would
    /// over-couple the test to the current step layout — only that the
    /// terminal value is at least ~1.0 so SwiftUI progress UIs can rely on
    /// seeing a clean "done" signal.
    @Test func exportVaultZip_progressReachesOne() async throws {
        let root = try seedVault(raw: 1)
        defer { try? FileManager.default.removeItem(at: root) }

        VaultInitializer.testOverrideURL = root
        defer { VaultInitializer.testOverrideURL = nil }

        let box = ProgressBox()
        let zipURL = try await VaultExportService.shared.exportVaultZip(
            includes: .all,
            progress: { value in
                // Closure is `@MainActor @Sendable`; we're already on the
                // main actor here so the call into `box.update` is direct.
                box.update(value)
            }
        )
        defer { try? FileManager.default.removeItem(at: zipURL) }

        #expect(box.maxSeen >= 0.99)
    }
}

/// Tiny @MainActor sink that just records the highest progress value seen.
/// We isolate it to the main actor because `exportVaultZip`'s progress
/// callback is itself `@MainActor @Sendable` — keeping the storage on the
/// same actor avoids any cross-actor hop inside the test.
@MainActor
private final class ProgressBox {
    var maxSeen: Double = 0
    func update(_ v: Double) {
        if v > maxSeen { maxSeen = v }
    }
}
