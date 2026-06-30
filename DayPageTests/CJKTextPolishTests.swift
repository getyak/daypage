import XCTest
import DayPageModels
@testable import DayPage

final class CJKTextPolishTests: XCTestCase {

    private let hs = "\u{200A}"  // hair space
    private let fw = "\u{3000}"  // full-width space

    // MARK: - Pure Chinese (no change expected for hair spaces)

    func testPureChineseUnchanged() {
        let input = "今天天气很好。"
        XCTAssertEqual(CJKTextPolish.polish(input), input)
    }

    func testPureChineseWithCommaUnchanged() {
        let input = "早上好，世界！"
        XCTAssertEqual(CJKTextPolish.polish(input), input)
    }

    // MARK: - Pure English (no change expected)

    func testPureEnglishUnchanged() {
        let input = "Hello, world!"
        XCTAssertEqual(CJKTextPolish.polish(input), input)
    }

    func testPureEnglishWithNumbersUnchanged() {
        let input = "There are 42 items."
        XCTAssertEqual(CJKTextPolish.polish(input), input)
    }

    // MARK: - CJK + Latin mix: hair space insertion

    func testCJKThenLatinGetsHairSpace() {
        let input = "今天Hello"
        let expected = "今天\(hs)Hello"
        XCTAssertEqual(CJKTextPolish.polish(input), expected)
    }

    func testLatinThenCJKGetsHairSpace() {
        let input = "Hello今天"
        let expected = "Hello\(hs)今天"
        XCTAssertEqual(CJKTextPolish.polish(input), expected)
    }

    func testMixedSentenceHairSpaces() {
        let input = "今天天气好，visit北京"
        let expected = "今天天气好，visit\(hs)北京"
        XCTAssertEqual(CJKTextPolish.polish(input), expected)
    }

    // MARK: - Emoji: hair space NOT inserted adjacent to emoji

    func testEmojiNoHairSpace() {
        // Emoji is neither CJK nor Latin alphanumeric — no hair space
        let input = "😀好"
        XCTAssertEqual(CJKTextPolish.polish(input), input)
    }

    func testEmojiWithLatinNoHairSpace() {
        let input = "Hello😀World"
        XCTAssertEqual(CJKTextPolish.polish(input), input)
    }

    // MARK: - Full-width space: preserved, no hair space adjacent

    func testFullWidthSpacePreserved() {
        let input = "今天\(fw)明天"
        XCTAssertEqual(CJKTextPolish.polish(input), input)
    }

    func testNoHairSpaceAdjacentToFullWidthSpace() {
        // Latin next to full-width space should NOT get hair space
        let input = "Hello\(fw)你好"
        XCTAssertEqual(CJKTextPolish.polish(input), input)
    }

    // MARK: - Doubled punctuation collapse

    func testChineseThenASCIIPeriodCollapsed() {
        XCTAssertEqual(CJKTextPolish.polish("结束了。."), "结束了。")
    }

    func testASCIIThenChinesePeriodCollapsed() {
        XCTAssertEqual(CJKTextPolish.polish("结束了.。"), "结束了。")
    }

    func testDoubledCommaCollapsed() {
        XCTAssertEqual(CJKTextPolish.polish("好，,朋友"), "好，朋友")
    }

    func testDoubledExclamationCollapsed() {
        XCTAssertEqual(CJKTextPolish.polish("太好了！!"), "太好了！")
    }

    func testDoubledQuestionCollapsed() {
        XCTAssertEqual(CJKTextPolish.polish("真的？?"), "真的？")
    }

    // MARK: - Mixed half/full width in same string

    func testMixedHalfFullWidthMultipleRules() {
        // Both punctuation collapse and hair-space insertion
        let input = "Hello你好。.World"
        // Step 1: collapse → "Hello你好。World"
        // Step 2: hair space → "Hello\u{200A}你好。\u{200A}World"  — but "。W" is Chinese punct + Latin
        // "。" is in CJK Symbols block (0x3000-0x303F) → isCJK=true; "W" is Latin → hair space inserted
        let expected = "Hello\(hs)你好。\(hs)World"
        XCTAssertEqual(CJKTextPolish.polish(input), expected)
    }

    // MARK: - Edge cases

    func testEmptyStringUnchanged() {
        XCTAssertEqual(CJKTextPolish.polish(""), "")
    }

    func testSingleCharacterUnchanged() {
        XCTAssertEqual(CJKTextPolish.polish("好"), "好")
        XCTAssertEqual(CJKTextPolish.polish("A"), "A")
    }

    func testPureASCIIPunctuationUnchanged() {
        let input = "Hello, World!"
        XCTAssertEqual(CJKTextPolish.polish(input), input)
    }
}
