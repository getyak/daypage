#!/usr/bin/env xcrun swift
// Tests for CompilationService / EntityPageService JSON parsing logic.
// Run: xcrun swift scripts/tests/test_compilation_parsing.swift

import Foundation

// MARK: - Inline the parsing logic under test

func extractJSONBlock(from text: String) -> String? {
    let fencePatterns = ["```json\n", "```json \n", "```JSON\n", "```\n"]
    for pattern in fencePatterns {
        if let fenceStart = text.range(of: pattern, options: .caseInsensitive),
           let fenceEnd = text.range(of: "\n```", range: fenceStart.upperBound ..< text.endIndex) {
            return String(text[fenceStart.upperBound ..< fenceEnd.lowerBound])
        }
    }
    if let braceStart = text.firstIndex(of: "{"),
       let braceEnd = text.lastIndex(of: "}") {
        return String(text[braceStart ... braceEnd])
    }
    return nil
}

/// Returns ("", []) sentinel on failure — empty dailyPage means parse failed.
func parseStructuredOutput(_ rawLLMResponse: String) -> (dailyPage: String, hasEntityUpdates: Bool) {
    guard let jsonBlock = extractJSONBlock(from: rawLLMResponse),
          let data = jsonBlock.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let dailyPage = json["daily_page"] as? String,
          !dailyPage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return ("", false)
    }
    let hasUpdates = (json["entity_updates"] as? [[String: Any]])?.isEmpty == false
    return (dailyPage, hasUpdates)
}

// MARK: - Test runner

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

func assertTrue(_ condition: Bool, _ message: String = "condition false") throws {
    if !condition {
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Tests

print("\n=== Compilation Parsing Tests ===\n")

test("bare JSON parsed correctly") {
    let raw = #"{"daily_page": "# Day\nContent here", "entity_updates": [], "hot_cache": "summary"}"#
    let (page, _) = parseStructuredOutput(raw)
    try assertTrue(!page.isEmpty, "dailyPage should not be empty")
    try assertTrue(page.contains("Content here"), "dailyPage should contain expected text")
}

test("markdown-fenced ```json block parsed correctly") {
    let raw = """
    Here is your output:
    ```json
    {"daily_page": "# Daily\nNarrative.", "entity_updates": [], "hot_cache": "cache"}
    ```
    That's all.
    """
    let (page, _) = parseStructuredOutput(raw)
    try assertTrue(!page.isEmpty, "should extract dailyPage from fenced block")
    try assertTrue(page.contains("Narrative"), "content should match")
}

test("uppercase ```JSON fence parsed correctly") {
    let raw = """
    ```JSON
    {"daily_page": "# Entry", "entity_updates": []}
    ```
    """
    let (page, _) = parseStructuredOutput(raw)
    try assertTrue(!page.isEmpty, "uppercase JSON fence should be handled")
}

test("plain ``` fence parsed correctly") {
    let raw = """
    ```
    {"daily_page": "# Plain fence", "entity_updates": []}
    ```
    """
    let (page, _) = parseStructuredOutput(raw)
    try assertTrue(!page.isEmpty, "plain fence should be handled")
}

test("missing daily_page field returns empty sentinel") {
    let raw = #"{"entity_updates": [], "hot_cache": "some cache"}"#
    let (page, _) = parseStructuredOutput(raw)
    try assertEqual(page, "", "missing daily_page should return empty sentinel")
}

test("empty daily_page string returns empty sentinel") {
    let raw = #"{"daily_page": "  ", "entity_updates": []}"#
    let (page, _) = parseStructuredOutput(raw)
    try assertEqual(page, "", "whitespace-only daily_page should return empty sentinel")
}

test("invalid JSON returns empty sentinel") {
    let raw = "This is just plain text, not JSON at all."
    let (page, _) = parseStructuredOutput(raw)
    try assertEqual(page, "", "plain text should return empty sentinel")
}

test("truncated JSON returns empty sentinel") {
    let raw = #"{"daily_page": "# Start"#  // missing closing brace
    let (page, _) = parseStructuredOutput(raw)
    try assertEqual(page, "", "truncated JSON should return empty sentinel")
}

test("entity_updates correctly detected") {
    let raw = """
    {"daily_page": "# Day", "entity_updates": [{"entity_type": "places", "entity_slug": "tokyo", "display_name": "Tokyo", "section": "## Visits", "content": "Visited today"}], "hot_cache": ""}
    """
    let (page, hasUpdates) = parseStructuredOutput(raw)
    try assertTrue(!page.isEmpty, "dailyPage should be present")
    try assertTrue(hasUpdates, "entity_updates should be detected")
}

test("extractJSONBlock prefers fenced over bare braces") {
    let raw = """
    Some text with a { stray brace } in it.
    ```json
    {"daily_page": "# Correct", "entity_updates": []}
    ```
    """
    let block = extractJSONBlock(from: raw)
    try assertTrue(block != nil, "should find a JSON block")
    try assertTrue(block!.contains("Correct"), "should prefer fenced block content")
}

print("\n=== Results: \(passed) passed, \(failed) failed ===")
if failed > 0 { exit(1) } else { exit(0) }
