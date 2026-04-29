import Foundation

// Manages first-launch initialization of the Vault directory structure
// under the App Sandbox Documents directory.
enum VaultInitializer {

    // MARK: - Vault root

    /// Swappable storage backend. Lazily resolved: uses iCloudVaultLocator when
    /// the ubiquity container is available; falls back to LocalVaultLocator otherwise.
    /// Can be overridden at runtime (e.g., after the user enables iCloud in Settings).
    static var shared: VaultLocator = {
        let icloud = iCloudVaultLocator()
        return icloud.isUsingiCloud ? icloud : LocalVaultLocator()
    }()

    /// Test-only override. When non-nil, `vaultURL` returns this instead of the
    /// locator-derived URL. Keep `internal` so `@testable import DayPage` tests
    /// can set/clear it; production code never touches it.
    static var testOverrideURL: URL?

    static var vaultURL: URL {
        if let override = testOverrideURL { return override }
        return shared.vaultURL
    }

    // MARK: - Public entry point

    /// Creates all required directories and seed files if they don't already exist.
    /// Safe to call on every launch — operations are idempotent.
    /// When attachmentPolicy == .alwaysLocal, also triggers download of any
    /// evicted iCloud attachment files under vault/raw/assets/.
    /// When iCloud is available and vaultLocation == .local, triggers migration.
    static func initializeIfNeeded() {
        createDirectories()
        createSeedFiles()
        prefetchAttachmentsIfNeeded()
        triggerMigrationIfNeeded()
    }

    // MARK: - iCloud Migration Trigger

    private static func triggerMigrationIfNeeded() {
        // Reuse the already-resolved shared locator instead of constructing a new
        // iCloudVaultLocator — avoids a redundant ubiquity-container lookup.
        guard shared.isUsingiCloud else { return }
        guard AppSettings.currentVaultLocation() == .local else { return }
        Task { @MainActor in
            VaultMigrationService.shared.migrateIfNeeded()
        }
    }

    // MARK: - Attachment prefetch (alwaysLocal policy)

    private static func prefetchAttachmentsIfNeeded() {
        // Only relevant when vault is iCloud-backed and user wants all attachments local.
        guard shared.isUsingiCloud else { return }
        guard AppSettings.currentAttachmentPolicy() == .alwaysLocal else { return }
        let assetsURL = vaultURL.appendingPathComponent("raw/assets", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: assetsURL,
            includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                  let status = values.ubiquitousItemDownloadingStatus,
                  status != .current else { continue }
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        }
    }

    // MARK: - Directories

    private static let requiredDirectories: [String] = [
        "raw/assets",
        "wiki/daily",
        "wiki/places",
        "wiki/people",
        "wiki/themes",
    ]

    private static func createDirectories() {
        let fm = FileManager.default
        for relativePath in requiredDirectories {
            let url = vaultURL.appendingPathComponent(relativePath, isDirectory: true)
            guard !fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                DayPageLogger.log(level: "ERROR", message: "Failed to create directory \(relativePath): \(error)")
            }
        }
    }

    // MARK: - Seed files

    private static func createSeedFiles() {
        writeIfAbsent(relativePath: "SCHEMA.md", content: schemaContent)
        writeIfAbsent(relativePath: "wiki/index.md", content: wikiIndexContent)
        writeIfAbsent(relativePath: "wiki/hot.md", content: hotContent)
        writeIfAbsent(relativePath: "wiki/log.md", content: logContent)
    }

    private static func writeIfAbsent(relativePath: String, content: String) {
        let url = vaultURL.appendingPathComponent(relativePath)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = Data(content.utf8)
            try data.write(to: url, options: .atomic)
        } catch {
            DayPageLogger.log(level: "ERROR", message: "Failed to write \(relativePath): \(error)")
        }
    }

    // MARK: - Seed content

    private static let schemaContent = """
    ---
    type: schema
    version: "1.0"
    created: \(iso8601Today())
    ---

    # DayPage Vault Schema

    ## Directory Layout

    ```
    vault/
    ├── raw/
    │   ├── assets/          # Audio, photo attachments
    │   └── YYYY-MM-DD.md    # Daily raw memo files
    └── wiki/
        ├── daily/           # AI-compiled Daily Pages
        ├── places/          # Entity pages — locations
        ├── people/          # Entity pages — people
        ├── themes/          # Entity pages — recurring themes
        ├── index.md         # Auto-generated entity index
        ├── hot.md           # Short-term memory context for AI compiler
        └── log.md           # Compilation audit log
    ```

    ## Memo Format

    Each memo in a `raw/YYYY-MM-DD.md` file uses YAML frontmatter + Markdown body,
    separated from adjacent memos by `\\n\\n---\\n\\n`.

    ```markdown
    ---
    id: <UUID>
    type: text | voice | photo | location | mixed
    created: <ISO-8601>
    location:
      name: <reverse-geocoded place name>
      lat: <latitude>
      lng: <longitude>
    weather: "<temp>°C, <description>"
    device: <model string>
    attachments: []
    ---

    Memo body text here.
    ```
    """

    private static let wikiIndexContent = """
    ---
    type: index
    updated: \(iso8601Today())
    ---

    # Entity Index

    ## Places
    <!-- auto-generated -->

    ## People
    <!-- auto-generated -->

    ## Themes
    <!-- auto-generated -->
    """

    private static let hotContent = """
    ---
    type: hot_cache
    updated: \(iso8601Today())
    covers_dates: []
    ---

    # Hot Cache

    _This file is automatically overwritten after each compilation.
    It provides short-term memory context to the AI compiler._
    """

    private static let logContent = """
    ---
    type: compilation_log
    created: \(iso8601Today())
    ---

    # Compilation Log

    | timestamp | trigger | duration_s | memo_count | status |
    |-----------|---------|-----------|------------|--------|
    """

    // MARK: - Helpers

    private static func iso8601Today() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date())
    }
}
