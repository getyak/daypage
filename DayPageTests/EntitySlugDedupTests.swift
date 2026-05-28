import Testing
import Foundation
@testable import DayPage

/// US-025: Entity slug dedup + fuzzy matching.
///
/// Serialized because tests mutate global `VaultInitializer.testOverrideURL`
/// and exercise `EntityPageService.shared` (singleton).
@Suite("EntitySlugDedupTests", .serialized)
struct EntitySlugDedupTests {

    private let tempDir: URL
    private let fm = FileManager.default
    private var service: EntityPageService { EntityPageService.shared }

    init() throws {
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("EntitySlugTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    private func cleanup() {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
    }

    // MARK: - sanitizeSlug

    @Test func sanitizeSlug_lowercasesAndHyphenates() {
        defer { cleanup() }
        #expect(EntityPageService.sanitizeSlug("Coffee Shop") == "coffee-shop")
    }

    @Test func sanitizeSlug_stripsCamelCase() {
        defer { cleanup() }
        #expect(EntityPageService.sanitizeSlug("CoffeeShop") == "coffeeshop")
    }

    @Test func sanitizeSlug_trimsLeadingTrailingWhitespace() {
        defer { cleanup() }
        #expect(EntityPageService.sanitizeSlug("  Bangkok  ") == "bangkok")
    }

    @Test func sanitizeSlug_collapsesMultipleSpaces() {
        defer { cleanup() }
        #expect(EntityPageService.sanitizeSlug("Joma  Coffee") == "joma-coffee")
    }

    // MARK: - isFuzzyMatch: hyphen-stripped equality

    @Test func fuzzyMatch_hyphenStripped_coffeeShopVariants() {
        defer { cleanup() }
        // "coffee-shop" and "coffeeshop" differ only by a hyphen
        #expect(service.isFuzzyMatch("coffee-shop", "coffeeshop"))
        #expect(service.isFuzzyMatch("coffeeshop", "coffee-shop"))
    }

    @Test func fuzzyMatch_hyphenStripped_multiHyphen() {
        defer { cleanup() }
        #expect(service.isFuzzyMatch("new-york-city", "newyorkcity"))
    }

    @Test func fuzzyMatch_editDistance_smallDiff() {
        defer { cleanup() }
        // "joma-coffe" vs "joma-coffee" — edit distance 1
        #expect(service.isFuzzyMatch("joma-coffe", "joma-coffee"))
    }

    @Test func fuzzyMatch_sharedPrefix() {
        defer { cleanup() }
        // share 6-char prefix "bangko"
        #expect(service.isFuzzyMatch("bangkokx", "bangkoky"))
    }

    @Test func fuzzyMatch_dissimilarSlugs_returnsFalse() {
        defer { cleanup() }
        #expect(!service.isFuzzyMatch("alice", "bangkok"))
        #expect(!service.isFuzzyMatch("coffee-shop", "tea-house"))
    }

    // MARK: - resolveSlug: dedup via apply()

    private func makeWikiDir(type: String) throws -> URL {
        let dir = tempDir
            .appendingPathComponent("wiki/\(type)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedEntity(type: String, slug: String) throws {
        let dir = try makeWikiDir(type: type)
        let file = dir.appendingPathComponent("\(slug).md")
        let content = """
            ---
            type: \(type.dropLast())
            name: "\(slug)"
            slug: \(slug)
            first_seen: 2026-01-01
            last_updated: 2026-01-01T00:00:00Z
            occurrence_count: 1
            ---

            # \(slug)
            """
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    /// "coffee shop" (with space) should map to existing "coffee-shop" slug.
    @Test func apply_dedupsSpacedVariant() throws {
        defer { cleanup() }
        try seedEntity(type: "places", slug: "coffee-shop")

        let instruction = EntityUpdateInstruction(
            entityType: "places",
            entitySlug: EntityPageService.sanitizeSlug("coffee shop"),
            section: "## Visits",
            content: "- 2026-05-27: test",
            displayName: "Coffee Shop"
        )

        try service.apply(instructions: [instruction], date: "2026-05-27")

        // Only "coffee-shop.md" should exist — no new file created.
        let dir = tempDir.appendingPathComponent("wiki/places")
        let files = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".md") }
        #expect(files == ["coffee-shop.md"],
                "Dedup should reuse existing coffee-shop.md, not create a new file")
    }

    /// "CoffeeShop" (camelCase) → sanitize → "coffeeshop" → fuzzy matches existing "coffee-shop".
    @Test func apply_dedupsCamelCaseVariant() throws {
        defer { cleanup() }
        try seedEntity(type: "places", slug: "coffee-shop")

        let instruction = EntityUpdateInstruction(
            entityType: "places",
            entitySlug: EntityPageService.sanitizeSlug("CoffeeShop"),
            section: "## Visits",
            content: "- 2026-05-27: test",
            displayName: "CoffeeShop"
        )

        try service.apply(instructions: [instruction], date: "2026-05-27")

        let dir = tempDir.appendingPathComponent("wiki/places")
        let files = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".md") }
        #expect(files == ["coffee-shop.md"],
                "CoffeeShop should fuzzy-merge into existing coffee-shop.md")
    }

    /// Two distinct slugs must NOT be merged.
    @Test func apply_distinctEntitiesCreatedSeparately() throws {
        defer { cleanup() }
        _ = try makeWikiDir(type: "places")

        let i1 = EntityUpdateInstruction(
            entityType: "places",
            entitySlug: EntityPageService.sanitizeSlug("Alice"),
            section: "## Notes",
            content: "- test",
            displayName: "Alice"
        )
        let i2 = EntityUpdateInstruction(
            entityType: "places",
            entitySlug: EntityPageService.sanitizeSlug("Bangkok"),
            section: "## Notes",
            content: "- test",
            displayName: "Bangkok"
        )

        try service.apply(instructions: [i1, i2], date: "2026-05-27")

        let dir = tempDir.appendingPathComponent("wiki/places")
        let files = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".md") }
            .sorted()
        #expect(files == ["alice.md", "bangkok.md"],
                "Distinct entities must not be merged")
    }
}
