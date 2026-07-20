import Foundation
import DayPageModels

// Manages first-launch initialization of the Vault directory structure
// under the App Sandbox Documents directory.
public enum VaultInitializer {

    // MARK: - Vault root

    /// Swappable storage backend.
    ///
    /// Defaults to `LocalVaultLocator` — a pure local-Documents path that never
    /// touches the iCloud daemon. This is deliberate: `iCloudVaultLocator`
    /// resolves the ubiquity container via `FileManager.url(forUbiquityContainerIdentifier:)`,
    /// which Apple documents as a *blocking* call that must not run on the main
    /// thread. `initializeIfNeeded()` reads `vaultURL` 13+ times synchronously
    /// inside `DayPageApp.init()` (before the first frame). On a fresh install the
    /// iCloud daemon hasn't provisioned the container yet, so each call could hang
    /// for seconds — enough to blow past the launch watchdog (~20s) and get the
    /// process killed with `0x8badf00d` (symptom: blank screen, then crash on
    /// first launch after reinstall).
    ///
    /// iCloud detection is instead performed off the main thread in
    /// `DayPageApp.init`'s `Task.detached` re-probe, which hot-swaps this locator
    /// to `iCloudVaultLocator` once the container becomes available. Runtime
    /// readers (`MemoCardView`, the sync/conflict monitors, migration) observe the
    /// swap transparently. Can also be overridden at runtime (e.g., after the user
    /// toggles iCloud in Settings).
    public static var shared: VaultLocator = LocalVaultLocator()

    /// Test-only override. When non-nil, `vaultURL` returns this instead of the
    /// locator-derived URL. Keep `internal` so `@testable import DayPage` tests
    /// can set/clear it; production code never touches it.
    public static var testOverrideURL: URL?

    public static var vaultURL: URL {
        if let override = testOverrideURL { return override }
        return shared.vaultURL
    }

    // MARK: - Public entry point

    /// Creates all required directories and seed files if they don't already exist.
    /// Safe to call on every launch — operations are idempotent.
    /// When attachmentPolicy == .alwaysLocal, also triggers download of any
    /// evicted iCloud attachment files under vault/raw/assets/.
    /// When iCloud is available and vaultLocation == .local, triggers migration.
    public static func initializeIfNeeded() {
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
        guard StorageSettings.currentVaultLocation() == .local else { return }
        VaultMigrationHook.fire()
    }

    // MARK: - Attachment prefetch (alwaysLocal policy)

    private static func prefetchAttachmentsIfNeeded() {
        // Only relevant when vault is iCloud-backed and user wants all attachments local.
        guard shared.isUsingiCloud else { return }
        guard StorageSettings.currentAttachmentPolicy() == .alwaysLocal else { return }
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

    // MARK: - Asset directory

    /// URL of the `vault/raw/assets/` directory where all binary attachments
    /// (photos, voice recordings, watch audio) live. Pure path derivation — does
    /// not touch the filesystem. Use `assetsDirectory()` when you also need the
    /// directory to exist.
    public static var assetsDirectoryURL: URL {
        vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("assets")
    }

    /// Ensures `vault/raw/assets/` exists and returns its URL so callers can
    /// write into it immediately. Throws if directory creation fails.
    ///
    /// Callers that need a vault-relative path for frontmatter should use
    /// `"raw/assets/\(filename)"`.
    @discardableResult
    public static func assetsDirectory() throws -> URL {
        let url = assetsDirectoryURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Directories

    private static let requiredDirectories: [String] = [
        "raw/assets",
        "wiki/daily",
        "wiki/places",
        "wiki/people",
        "wiki/themes",
        // R7 — weekly recap output lands here as `{ISOWeek}.md`.
        "wiki/weekly",
        // D1 — MemoryChatService persists past AI conversations here as
        // `{YYYY-MM-DD}.jsonl` so history survives across app launches.
        "wiki/chats",
    ]

    private static func createDirectories() {
        let fm = FileManager.default
        for relativePath in requiredDirectories {
            let url = vaultURL.appendingPathComponent(relativePath, isDirectory: true)
            guard !fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                SentryReporter.breadcrumb(category: "vault-init", level: .error, message: "Failed to create directory \(relativePath): \(error)")
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
            SentryReporter.breadcrumb(category: "vault-init", level: .error, message: "Failed to write \(relativePath): \(error)")
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
