import XCTest
import UIKit
@testable import DayPage

final class MemoReadingTests: XCTestCase {
    @MainActor
    func testRepeatedLayoutInputsKeepTheMeasuredDocumentGeneration() {
        let label = MemoReadingLabel()
        label.updateDocument(text: "保留原文。", category: .large, expanded: false, budget: 6)
        let initialGeneration = label.generation
        label.lastMeasurement = "measured"
        label.updateDocument(text: "保留原文。", category: .large, expanded: false, budget: 6)
        XCTAssertEqual(label.generation, initialGeneration)
        XCTAssertEqual(label.lastMeasurement, "measured")
        label.updateDocument(text: "保留原文。", category: .large, expanded: true, budget: 6)
        XCTAssertEqual(label.generation, initialGeneration + 1)
        XCTAssertNil(label.lastMeasurement)
        label.updateDocument(text: "保留原文。", category: .accessibilityExtraExtraExtraLarge, expanded: true, budget: 6)
        XCTAssertEqual(label.generation, initialGeneration + 2)
    }

    @MainActor
    func testSingleLineSourcePreviewStaysInsideItsProposedWidth() {
        let label = MemoReadingLabel()
        label.budget = 1
        label.attributedText = MemoReadingDocument.attributed(String(repeating: "完整原文应保留在边界之内。", count: 80), category: .large)
        let size = label.readingSize(width: 276)
        XCTAssertEqual(size.width, 276)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThanOrEqual(size.height, 30)
        XCTAssertTrue(MemoReadingMetrics.measure(label.attributedText ?? NSAttributedString(), width: 276, lines: 1).overflows)
    }

    @MainActor
    func testPreviewPreservesParagraphsAndNumberedListOrigin() {
        DSFonts.registerAll()
        let value = MemoReadingDocument.attributed(
            "第一段。\n\n第二段。\n\n7. 保留原始记录\n8. Keep the original words",
            category: .large
        ).string
        XCTAssertTrue(value.contains("第一段。\n第二段。"))
        XCTAssertTrue(value.contains("7. 保留原始记录\n8. Keep the original words"))
    }

    @MainActor
    func testActualLayoutDetectsOverflowAndReflowsAtNewWidth() {
        DSFonts.registerAll()
        let text = MemoReadingDocument.attributed(String(repeating: "记录应该保留完整的段落与原来的声音。", count: 8), category: .large)
        XCTAssertTrue(MemoReadingMetrics.measure(text, width: 276, lines: 5).overflows)
        XCTAssertFalse(MemoReadingMetrics.measure(text, width: 2_000, lines: 6).overflows)
        let short = MemoReadingDocument.attributed("为自己留下一点自由。", category: .large)
        XCTAssertFalse(MemoReadingMetrics.measure(short, width: 276, lines: 5).overflows)
    }

    @MainActor
    func testLargeTypeChangesTheActualMeasuredText() {
        DSFonts.registerAll()
        let source = "回家时没有戴耳机。雨停了，路边的树还在滴水。"
        let normal = MemoReadingDocument.attributed(source, category: .large)
        let large = MemoReadingDocument.attributed(source, category: .accessibilityExtraExtraExtraLarge)
        XCTAssertGreaterThan(MemoReadingMetrics.measure(large, width: 311, lines: 6).fullHeight,
                             MemoReadingMetrics.measure(normal, width: 311, lines: 6).fullHeight)
        XCTAssertEqual(normal.string, large.string)
    }

    @MainActor
    func testMixedUnicodeAndLongLinkRemainWhole() {
        let source = "一起读 👩🏽‍💻，一起记。\n\n[原始链接](https://example.invalid/" + String(repeating: "long-path-", count: 40) + ")"
        let value = MemoReadingDocument.attributed(source, category: .large)
        XCTAssertTrue(value.string.contains("👩🏽‍💻"))
        XCTAssertTrue(value.string.contains("原始链接"))
        XCTAssertNotNil(value.attribute(.foregroundColor, at: value.length - 1, effectiveRange: nil))
    }
}
