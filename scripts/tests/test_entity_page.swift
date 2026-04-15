#!/usr/bin/env xcrun swift
// Unit tests for EntityPageService logic (pure Swift, no UIKit/AppKit needed).
// Run: xcrun swift scripts/tests/test_entity_page.swift
//
// Tests:
//  1. sanitizeSlug - slug normalization
//  2. parseStructuredOutput - JSON extraction from LLM response
//  3. appendUnderSection - section insertion in existing page
//  4. appendUnderSection - new section creation when not found
//  5. updateFrontmatterField - frontmatter key update
//  6. incrementFrontmatterCount - occurrence_count increment
//  7. Full create-then-update lifecycle in temp directory

import Foundation

// MARK: - Minimal stubs for types used by EntityPageService

struct EntityUpdateInstruction {
    let entityType: String
    let entitySlug: String
    let section: String
    let content: String
    let displayName: String
}

// MARK: - Inlined EntityPageService logic (pure functions only, no @MainActor singleton)

func sanitizeSlug(_ raw: String) -> String {
    raw
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
        .joined(separator: "-")
        .components(separatedBy: "-")
        .filter { !$0.isEmpty }
        .joined(separator: "-")
}

func headingLevel(of line: String) -> Int {
    var level = 0
    for char in line {
        if char == "#" { level += 1 } else { break }
    }
    return level
}

func appendUnderSection(content: String, section sectionHeading: String, newContent: String) -> String {
    var lines = content.components(separatedBy: "\n")

    if let sectionIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == sectionHeading }) {
        let level = headingLevel(of: sectionHeading)
        var insertIndex = sectionIndex + 1
        while insertIndex < lines.count {
            let line = lines[insertIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") && headingLevel(of: trimmed) <= level {
                break
            }
            insertIndex += 1
        }
        while insertIndex > sectionIndex + 1 && lines[insertIndex - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            insertIndex -= 1
        }
        let insertion = ["", newContent, ""]
        lines.insert(contentsOf: insertion, at: insertIndex)
    } else {
        lines.append("")
        lines.append(sectionHeading)
        lines.append("")
        lines.append(newContent)
        lines.append("")
    }

    return lines.joined(separator: "\n")
}

func updateFrontmatterField(in content: String, key: String, value: String) -> String {
    let lines = content.components(separatedBy: "\n")
    var result: [String] = []
    var inFrontmatter = false
    var closingFound = false

    for (index, line) in lines.enumerated() {
        if index == 0 && line.trimmingCharacters(in: .whitespaces) == "---" {
            inFrontmatter = true
            result.append(line)
            continue
        }
        if inFrontmatter && !closingFound && line.trimmingCharacters(in: .whitespaces) == "---" {
            closingFound = true
            inFrontmatter = false
            result.append(line)
            continue
        }
        if inFrontmatter {
            let prefix = "\(key): "
            if line.hasPrefix(prefix) {
                result.append("\(key): \(value)")
                continue
            }
        }
        result.append(line)
    }
    return result.joined(separator: "\n")
}

func incrementFrontmatterCount(in content: String, key: String) -> String {
    let lines = content.components(separatedBy: "\n")
    var result: [String] = []
    var inFrontmatter = false
    var closingFound = false

    for (index, line) in lines.enumerated() {
        if index == 0 && line.trimmingCharacters(in: .whitespaces) == "---" {
            inFrontmatter = true
            result.append(line)
            continue
        }
        if inFrontmatter && !closingFound && line.trimmingCharacters(in: .whitespaces) == "---" {
            closingFound = true
            inFrontmatter = false
            result.append(line)
            continue
        }
        if inFrontmatter {
            let prefix = "\(key): "
            if line.hasPrefix(prefix) {
                let raw = String(line.dropFirst(prefix.count))
                let current = Int(raw.trimmingCharacters(in: .whitespaces)) ?? 0
                result.append("\(key): \(current + 1)")
                continue
            }
        }
        result.append(line)
    }
    return result.joined(separator: "\n")
}

func extractJSONBlock(from text: String) -> String? {
    if let fenceStart = text.range(of: "```json\n"),
       let fenceEnd = text.range(of: "\n```", range: fenceStart.upperBound ..< text.endIndex) {
        return String(text[fenceStart.upperBound ..< fenceEnd.lowerBound])
    }
    if let braceStart = text.firstIndex(of: "{"),
       let braceEnd = text.lastIndex(of: "}") {
        return String(text[braceStart ... braceEnd])
    }
    return nil
}

func parseStructuredOutput(_ rawLLMResponse: String) -> (dailyPage: String, instructions: [EntityUpdateInstruction]) {
    guard let jsonBlock = extractJSONBlock(from: rawLLMResponse),
          let data = jsonBlock.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return (rawLLMResponse, [])
    }
    let dailyPage = (json["daily_page"] as? String) ?? rawLLMResponse
    var instructions: [EntityUpdateInstruction] = []
    if let updates = json["entity_updates"] as? [[String: Any]] {
        for update in updates {
            guard
                let entityType = update["entity_type"] as? String,
                let entitySlug = update["entity_slug"] as? String,
                let displayName = update["display_name"] as? String,
                let section = update["section"] as? String,
                let content = update["content"] as? String,
                ["places", "people", "themes"].contains(entityType)
            else { continue }
            instructions.append(EntityUpdateInstruction(
                entityType: entityType,
                entitySlug: sanitizeSlug(entitySlug),
                section: section,
                content: content,
                displayName: displayName
            ))
        }
    }
    return (dailyPage, instructions)
}

// MARK: - Test Harness

var passed = 0
var failed = 0

func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("  PASS  \(name)")
        passed += 1
    } catch {
        print("  FAIL  \(name): \(error)")
        failed += 1
    }
}

func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: Int = #line) throws {
    if lhs != rhs {
        throw NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Expected \(rhs), got \(lhs) at line \(line)"
        ])
    }
}

func assertTrue(_ condition: Bool, _ message: String = "condition false", file: StaticString = #file, line: Int = #line) throws {
    if !condition {
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Tests

print("=== EntityPageService Tests ===\n")

// Test 1: slug normalization
test("sanitizeSlug basic") {
    try assertEqual(sanitizeSlug("Joma Coffee"), "joma-coffee")
}
test("sanitizeSlug with special chars") {
    // é is kept (Unicode letter), ! is stripped, spaces become hyphens
    let result = sanitizeSlug("Caf\u{00E9} du Monde!")
    try assertTrue(result.contains("caf"), "Should contain lowercased caf prefix")
    try assertTrue(!result.contains(" "), "Should not contain spaces")
    try assertTrue(!result.contains("!"), "Should not contain exclamation mark")
}
test("sanitizeSlug already clean") {
    try assertEqual(sanitizeSlug("joma-coffee"), "joma-coffee")
}
test("sanitizeSlug consecutive hyphens") {
    try assertEqual(sanitizeSlug("hello--world"), "hello-world")
}

// Test 2: parseStructuredOutput - JSON fenced block
test("parseStructuredOutput with fenced JSON") {
    let response = """
    ```json
    {
      "daily_page": "# 2026-01-15",
      "entity_updates": [
        {
          "entity_type": "places",
          "entity_slug": "joma-coffee",
          "display_name": "Joma Coffee",
          "section": "## Visits",
          "content": "- 2026-01-15: Had an Americano"
        }
      ]
    }
    ```
    """
    let (dailyPage, instructions) = parseStructuredOutput(response)
    try assertEqual(dailyPage, "# 2026-01-15")
    try assertEqual(instructions.count, 1)
    try assertEqual(instructions[0].entityType, "places")
    try assertEqual(instructions[0].entitySlug, "joma-coffee")
    try assertEqual(instructions[0].displayName, "Joma Coffee")
    try assertEqual(instructions[0].section, "## Visits")
    try assertTrue(instructions[0].content.contains("Americano"))
}

// Test 3: parseStructuredOutput - invalid entity_type filtered out
test("parseStructuredOutput filters invalid entity_type") {
    let response = """
    {
      "daily_page": "# Page",
      "entity_updates": [
        {
          "entity_type": "invalid",
          "entity_slug": "test",
          "display_name": "Test",
          "section": "## Notes",
          "content": "some content"
        },
        {
          "entity_type": "themes",
          "entity_slug": "productivity",
          "display_name": "Productivity",
          "section": "## Notes",
          "content": "focus day"
        }
      ]
    }
    """
    let (_, instructions) = parseStructuredOutput(response)
    try assertEqual(instructions.count, 1)
    try assertEqual(instructions[0].entityType, "themes")
}

// Test 4: parseStructuredOutput - fallback on invalid JSON
test("parseStructuredOutput fallback on invalid JSON") {
    let raw = "# This is just a plain daily page\n\nSome content."
    let (dailyPage, instructions) = parseStructuredOutput(raw)
    try assertEqual(dailyPage, raw)
    try assertEqual(instructions.count, 0)
}

// Test 5: appendUnderSection - existing section
test("appendUnderSection inserts under existing section") {
    let content = """
    # Joma Coffee

    ## Visits

    - 2026-01-14: Previous visit

    ## Notes

    Some notes.
    """
    let result = appendUnderSection(
        content: content,
        section: "## Visits",
        newContent: "- 2026-01-15: New visit"
    )
    try assertTrue(result.contains("- 2026-01-14: Previous visit"))
    try assertTrue(result.contains("- 2026-01-15: New visit"))
    // New content should appear before ## Notes
    let visitsRange = result.range(of: "- 2026-01-15")!
    let notesRange = result.range(of: "## Notes")!
    try assertTrue(visitsRange.lowerBound < notesRange.lowerBound, "New visit should appear before ## Notes")
}

// Test 6: appendUnderSection - section not found, creates new
test("appendUnderSection creates new section when not found") {
    let content = """
    # Alice

    ## Mentions

    - 2026-01-14: Met at cafe
    """
    let result = appendUnderSection(
        content: content,
        section: "## Projects",
        newContent: "- DayPage collaboration"
    )
    try assertTrue(result.contains("## Projects"))
    try assertTrue(result.contains("- DayPage collaboration"))
}

// Test 7: updateFrontmatterField
test("updateFrontmatterField updates last_updated") {
    let page = """
    ---
    type: place
    name: "Joma Coffee"
    last_updated: 2026-01-14T10:00:00Z
    occurrence_count: 1
    ---

    # Joma Coffee
    """
    let result = updateFrontmatterField(
        in: page,
        key: "last_updated",
        value: "2026-01-15T09:00:00Z"
    )
    try assertTrue(result.contains("last_updated: 2026-01-15T09:00:00Z"))
    try assertTrue(!result.contains("last_updated: 2026-01-14T10:00:00Z"))
}

// Test 8: incrementFrontmatterCount
test("incrementFrontmatterCount increments from 1 to 2") {
    let page = """
    ---
    type: place
    occurrence_count: 1
    ---

    # Test
    """
    let result = incrementFrontmatterCount(in: page, key: "occurrence_count")
    try assertTrue(result.contains("occurrence_count: 2"))
    try assertTrue(!result.contains("occurrence_count: 1\n") || result.contains("occurrence_count: 2"))
}

test("incrementFrontmatterCount handles missing key gracefully") {
    let page = """
    ---
    type: place
    ---

    # Test
    """
    // Should not crash, just return unchanged content
    let result = incrementFrontmatterCount(in: page, key: "occurrence_count")
    try assertTrue(result.contains("type: place"))
}

// Test 9: Full lifecycle - create then update via temp directory
test("full lifecycle: create new entity page then update it") {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // Step 1: Create new entity page
    let entityURL = tmpDir.appendingPathComponent("joma-coffee.md")
    let firstSeen = "2026-01-15"
    let now = "2026-01-15T09:00:00Z"
    let instruction = EntityUpdateInstruction(
        entityType: "places",
        entitySlug: "joma-coffee",
        section: "## Visits",
        content: "- 2026-01-15: First visit, had Americano",
        displayName: "Joma Coffee"
    )

    // Build new page content
    let typeLabel = "Place"
    var lines: [String] = [
        "---",
        "type: place",
        "name: \"Joma Coffee\"",
        "slug: joma-coffee",
        "first_seen: \(firstSeen)",
        "last_updated: \(now)",
        "occurrence_count: 1",
        "---",
        "",
        "# Joma Coffee",
        "",
        "**Type**: \(typeLabel)  ",
        "**First seen**: \(firstSeen)",
        ""
    ]
    lines.append(instruction.section)
    lines.append("")
    lines.append(instruction.content)
    lines.append("")

    let initialContent = lines.joined(separator: "\n")
    try initialContent.write(to: entityURL, atomically: true, encoding: .utf8)

    // Verify initial content
    let readBack = try String(contentsOf: entityURL, encoding: .utf8)
    try assertTrue(readBack.contains("occurrence_count: 1"))
    try assertTrue(readBack.contains("- 2026-01-15: First visit"))

    // Step 2: Simulate a second day's update
    var updated = readBack
    updated = updateFrontmatterField(in: updated, key: "last_updated", value: "2026-01-16T09:00:00Z")
    updated = incrementFrontmatterCount(in: updated, key: "occurrence_count")
    updated = appendUnderSection(
        content: updated,
        section: "## Visits",
        newContent: "- 2026-01-16: Second visit, worked remotely"
    )
    try updated.write(to: entityURL, atomically: true, encoding: .utf8)

    // Verify updated content
    let finalContent = try String(contentsOf: entityURL, encoding: .utf8)
    try assertTrue(finalContent.contains("occurrence_count: 2"), "occurrence_count should be 2")
    try assertTrue(finalContent.contains("last_updated: 2026-01-16T09:00:00Z"), "last_updated should be updated")
    try assertTrue(finalContent.contains("- 2026-01-15: First visit"), "original visit should be preserved")
    try assertTrue(finalContent.contains("- 2026-01-16: Second visit"), "new visit should be added")
}

// Test 10: Multiple days referencing the same entity
test("multiple days referencing same entity accumulates correctly") {
    var content = """
    ---
    type: theme
    name: "Productivity"
    occurrence_count: 1
    ---

    # Productivity

    ## Notes

    - 2026-01-14: Initial entry
    """

    // Day 2
    content = updateFrontmatterField(in: content, key: "last_updated", value: "2026-01-15T10:00:00Z")
    content = incrementFrontmatterCount(in: content, key: "occurrence_count")
    content = appendUnderSection(content: content, section: "## Notes", newContent: "- 2026-01-15: Deep work session")

    // Day 3
    content = updateFrontmatterField(in: content, key: "last_updated", value: "2026-01-16T10:00:00Z")
    content = incrementFrontmatterCount(in: content, key: "occurrence_count")
    content = appendUnderSection(content: content, section: "## Notes", newContent: "- 2026-01-16: Pomodoro technique")

    try assertTrue(content.contains("occurrence_count: 3"), "Should have 3 occurrences after 3 days")
    try assertTrue(content.contains("- 2026-01-14: Initial entry"))
    try assertTrue(content.contains("- 2026-01-15: Deep work session"))
    try assertTrue(content.contains("- 2026-01-16: Pomodoro technique"))
}

// Test 11: parseStructuredOutput - multiple entity types
test("parseStructuredOutput handles multiple entity types") {
    let response = """
    {
      "daily_page": "# 2026-01-15\\n\\nToday I went to [[joma-coffee]] with [[alice]].",
      "entity_updates": [
        {
          "entity_type": "places",
          "entity_slug": "joma-coffee",
          "display_name": "Joma Coffee",
          "section": "## Visits",
          "content": "- 2026-01-15: Worked"
        },
        {
          "entity_type": "people",
          "entity_slug": "alice",
          "display_name": "Alice",
          "section": "## Mentions",
          "content": "- 2026-01-15: Met at Joma Coffee"
        },
        {
          "entity_type": "themes",
          "entity_slug": "remote-work",
          "display_name": "Remote Work",
          "section": "## Notes",
          "content": "- 2026-01-15: Productive day at cafe"
        }
      ]
    }
    """
    let (dailyPage, instructions) = parseStructuredOutput(response)
    try assertTrue(dailyPage.contains("[[joma-coffee]]"))
    try assertEqual(instructions.count, 3)
    try assertEqual(instructions.filter { $0.entityType == "places" }.count, 1)
    try assertEqual(instructions.filter { $0.entityType == "people" }.count, 1)
    try assertEqual(instructions.filter { $0.entityType == "themes" }.count, 1)
}

// MARK: - Summary
print("\n=== Results: \(passed) passed, \(failed) failed ===")
if failed > 0 {
    exit(1)
} else {
    exit(0)
}
