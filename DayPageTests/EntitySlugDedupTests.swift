import XCTest
@testable import DayPage

/// US-025: Entity slug dedup + fuzzy matching.
final class EntitySlugDedupTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default
    private var service: EntityPageService { EntityPageService.shared }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("EntitySlugTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - sanitizeSlug

    func testSanitizeSlug_lowercasesAndHyphenates() {
        XCTAssertEqual(EntityPageService.sanitizeSlug("Coffee Shop"), "coffee-shop")
    }

    func testSanitizeSlug_stripsCamelCase() {
        XCTAssertEqual(EntityPageService.sanitizeSlug("CoffeeShop"), "coffeeshop")
    }

    func testSanitizeSlug_trimsLeadingTrailingWhitespace() {
        XCTAssertEqual(EntityPageService.sanitizeSlug("  Bangkok  "), "bangkok")
    }

    func testSanitizeSlug_collapsesMultipleSpaces() {
        XCTAssertEqual(EntityPageService.sanitizeSlug("Joma  Coffee"), "joma-coffee")
    }

    // MARK: - isFuzzyMatch: hyphen-stripped equality

    func testFuzzyMatch_hyphenStripped_coffeeShopVariants() {
        // "coffee-shop" and "coffeeshop" differ only by a hyphen
        XCTAssertTrue(service.isFuzzyMatch("coffee-shop", "coffeeshop"))
        XCTAssertTrue(service.isFuzzyMatch("coffeeshop", "coffee-shop"))
    }

    func testFuzzyMatch_hyphenStripped_multiHyphen() {
        XCTAssertTrue(service.isFuzzyMatch("new-york-city", "newyorkcity"))
    }

    func testFuzzyMatch_editDistance_smallDiff() {
        // "joma-coffe" vs "joma-coffee" — edit distance 1
        XCTAssertTrue(service.isFuzzyMatch("joma-coffe", "joma-coffee"))
    }

    func testFuzzyMatch_sharedPrefix() {
        // share 6-char prefix "bangko"
        XCTAssertTrue(service.isFuzzyMatch("bangkokx", "bangkoky"))
    }

    func testFuzzyMatch_dissimilarSlugs_returnsFalse() {
        XCTAssertFalse(service.isFuzzyMatch("alice", "bangkok"))
        XCTAssertFalse(service.isFuzzyMatch("coffee-shop", "tea-house"))
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
    func testApply_dedupsSpacedVariant() throws {
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
        XCTAssertEqual(files, ["coffee-shop.md"], "Dedup should reuse existing coffee-shop.md, not create a new file")
    }

    /// "CoffeeShop" (camelCase) → sanitize → "coffeeshop" → fuzzy matches existing "coffee-shop".
    func testApply_dedupsCamelCaseVariant() throws {
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
        XCTAssertEqual(files, ["coffee-shop.md"],
                       "CoffeeShop should fuzzy-merge into existing coffee-shop.md")
    }

    /// Two distinct slugs must NOT be merged.
    func testApply_distinctEntitiesCreatedSeparately() throws {
        try makeWikiDir(type: "places")

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
        XCTAssertEqual(files, ["alice.md", "bangkok.md"],
                       "Distinct entities must not be merged")
    }
}
