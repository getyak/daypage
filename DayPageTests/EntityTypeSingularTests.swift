import Testing
import Foundation
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Fullchain audit Bug #4: `entityType.dropLast()` wrote `type: peopl` into
/// people-page frontmatter. These tests pin the explicit singular mapping and
/// the self-heal path for already-poisoned pages.
///
/// Uses a per-test `EntityPageService(vaultRootOverride:)` instance instead of
/// the global `VaultInitializer.testOverrideURL` — parallel suites race on
/// that global, which made these tests flake on CI while passing locally.
@Suite("EntityTypeSingularTests")
@MainActor
struct EntityTypeSingularTests {

    private let tempDir: URL
    private let fm = FileManager.default
    private let service: EntityPageService

    init() throws {
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("EntityTypeSingularTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = EntityPageService(vaultRootOverride: tempDir)
    }

    private func cleanup() {
        try? fm.removeItem(at: tempDir)
    }

    private func instruction(type: String, slug: String, name: String) -> EntityUpdateInstruction {
        EntityUpdateInstruction(
            entityType: type,
            entitySlug: slug,
            section: "## Mentions",
            content: "- 2026-07-16: test mention",
            displayName: name
        )
    }

    private func pageContent(type: String, slug: String) throws -> String {
        let url = tempDir.appendingPathComponent("wiki/\(type)/\(slug).md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - New-page frontmatter

    @Test func newPeoplePage_writesTypePerson() throws {
        defer { cleanup() }
        try service.apply(
            instructions: [instruction(type: "people", slug: "naomi", name: "Naomi")],
            date: "2026-07-16"
        )
        let content = try pageContent(type: "people", slug: "naomi")
        #expect(content.contains("\ntype: person\n"),
                "people pages must carry `type: person`, not the dropLast artifact `peopl`")
        #expect(!content.contains("peopl\n"))
    }

    @Test func newPlaceAndThemePages_keepCorrectSingulars() throws {
        defer { cleanup() }
        try service.apply(
            instructions: [
                instruction(type: "places", slug: "nimman", name: "宁曼路"),
                instruction(type: "themes", slug: "visa-run", name: "Visa Run"),
            ],
            date: "2026-07-16"
        )
        #expect(try pageContent(type: "places", slug: "nimman").contains("\ntype: place\n"))
        #expect(try pageContent(type: "themes", slug: "visa-run").contains("\ntype: theme\n"))
    }

    // MARK: - Self-heal of poisoned legacy pages

    @Test func appendToPoisonedPage_healsPeoplTypo() throws {
        defer { cleanup() }
        // Seed a legacy page exactly as the dropLast bug wrote it.
        let dir = tempDir.appendingPathComponent("wiki/people")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = """
        ---
        type: peopl
        name: "Naomi"
        slug: naomi
        first_seen: 2026-07-08
        last_updated: 2026-07-08T00:00:00.000Z
        occurrence_count: 1
        ---

        # Naomi

        ## Mentions

        - 2026-07-08: old mention
        """
        try legacy.write(to: dir.appendingPathComponent("naomi.md"), atomically: true, encoding: .utf8)

        try service.apply(
            instructions: [instruction(type: "people", slug: "naomi", name: "Naomi")],
            date: "2026-07-16"
        )

        let healed = try pageContent(type: "people", slug: "naomi")
        #expect(healed.contains("\ntype: person\n"),
                "appending to a legacy page must rewrite `type: peopl` → `type: person`")
        #expect(!healed.contains("type: peopl\n"))
        #expect(healed.contains("- 2026-07-08: old mention"),
                "healing must not disturb existing page content")
        #expect(healed.contains("- 2026-07-16: test mention"))
    }
}
