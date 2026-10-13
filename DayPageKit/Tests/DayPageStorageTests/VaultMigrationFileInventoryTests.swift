import XCTest
import Foundation
@testable import DayPageStorage

final class VaultMigrationFileInventoryTests: XCTestCase {
    private var root: URL!
    private let manager = FileManager.default
    private let capturePath = "raw/assets/.screenshot-captures/11111111-1111-1111-1111-111111111111.json"

    override func setUpWithError() throws {
        let parent = ProcessInfo.processInfo.environment["DAYPAGE_TEST_ARTIFACT_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? manager.temporaryDirectory
        root = parent.appendingPathComponent("migration-inventory-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try manager.removeItem(at: root) }
    }

    private func write(_ relative: String, bytes: Data = Data("synthetic".utf8)) throws {
        let url = root.appendingPathComponent(relative)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    func testCanonicalHiddenManifestTravelsWithRawAndOriginal() throws {
        try write("raw/2026-10-12.md")
        try write("raw/assets/screenshots/screenshot_11111111-1111-1111-1111-111111111111.png")
        try write(capturePath, bytes: Data("{\"phase\":\"ingestPending\"}".utf8))
        let files = try VaultMigrationFileInventory.relativeFiles(in: root)
        XCTAssertEqual(Set(files), Set([
            "raw/2026-10-12.md",
            "raw/assets/screenshots/screenshot_11111111-1111-1111-1111-111111111111.png",
            capturePath,
        ]))
    }

    func testUnrelatedHiddenFilesAndDirectoriesStayExcluded() throws {
        try write(capturePath)
        try write(".git/config")
        try write(".DS_Store")
        try write("raw/.private-cache/item")
        try write("raw/assets/.other-captures/item.json")
        try write("raw/assets/.screenshot-captures/.cache/item")
        XCTAssertEqual(try VaultMigrationFileInventory.relativeFiles(in: root), [capturePath])
    }

    func testDirectoryNameNearMissDoesNotGrantHiddenAccess() throws {
        try write("raw/assets/.screenshot-captures-old/item.json")
        try write("wiki/.screenshot-captures/item.json")
        XCTAssertEqual(try VaultMigrationFileInventory.relativeFiles(in: root), [])
    }

    func testMissingSourceCannotBecomeSuccessfulEmptyMigration() throws {
        XCTAssertThrowsError(try VaultMigrationFileInventory.relativeFiles(in: root.appendingPathComponent("missing")))
    }

    func testCanonicalManifestDirectorySymlinkFailsClosed() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("migration-outside-\(UUID().uuidString)")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: outside) }
        let sentinel = outside.appendingPathComponent("sentinel.json")
        let bytes = Data("synthetic outside sentinel".utf8)
        try bytes.write(to: sentinel)
        let link = root.appendingPathComponent("raw/assets/.screenshot-captures")
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try VaultMigrationFileInventory.relativeFiles(in: root))
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
    }

    func testInventoryCanDriveExactManifestCopy() throws {
        let bytes = Data("{\"phase\":\"understanding\",\"cloudConsentAtCapture\":false}".utf8)
        try write(capturePath, bytes: bytes)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let paths = try VaultMigrationFileInventory.relativeFiles(in: root)
        for relative in paths {
            let target = destination.appendingPathComponent(relative)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: root.appendingPathComponent(relative), to: target)
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(capturePath)), bytes)
    }
}
