import XCTest
@testable import DayPage

final class ComposerContextProviderTests: XCTestCase {

    private var provider: ComposerContextProvider!

    override func setUp() {
        super.setUp()
        provider = ComposerContextProvider()
    }

    override func tearDown() {
        provider = nil
        super.tearDown()
    }

    // MARK: - ContextChip id uniqueness

    func testContextChip_id_isUnique() {
        let chips: [ContextChip] = [
            .weather(temp: "20°C", condition: "Sunny"),
            .location(short: "Tokyo"),
            .timeRitual(emoji: "🌅", text: "早安"),
            .lastMemoTail(snippet: "hello world"),
            .smartPaste(value: "pasted text"),
        ]
        let ids = chips.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "Each ContextChip case must produce a unique id")
    }

    // MARK: - ContextChip Equatable

    func testContextChip_equalityByValue() {
        let a = ContextChip.weather(temp: "20°C", condition: "Cloudy")
        let b = ContextChip.weather(temp: "20°C", condition: "Cloudy")
        let c = ContextChip.weather(temp: "25°C", condition: "Sunny")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - chips always contains timeRitual

    func testChips_alwaysContainsTimeRitual() {
        let chips = provider.chips
        let hasRitual = chips.contains { if case .timeRitual = $0 { return true }; return false }
        XCTAssertTrue(hasRitual, "chips must always contain a timeRitual chip")
    }

    // MARK: - update memos feeds lastMemoTail

    func testChips_lastMemoTail_presentWhenMemosNonEmpty() {
        let memo = Memo(id: UUID(), type: .text, created: Date(), body: "今天遇到了一只猫")
        provider.update(memos: [memo])
        let chips = provider.chips
        let tailChip = chips.compactMap { if case .lastMemoTail(let s) = $0 { return s } else { return nil } }.first
        XCTAssertNotNil(tailChip, "lastMemoTail chip must be present when memos is non-empty")
        XCTAssertTrue(tailChip!.contains("今天遇到了一只猫"), "snippet must include the memo body tail")
    }

    func testChips_lastMemoTail_absentWhenMemosEmpty() {
        provider.update(memos: [])
        let chips = provider.chips
        let hasLastMemo = chips.contains { if case .lastMemoTail = $0 { return true }; return false }
        XCTAssertFalse(hasLastMemo, "lastMemoTail chip must be absent when memos is empty")
    }

    // MARK: - lastMemoTail snippet max length

    func testChips_lastMemoTail_snippetIsAtMost60Chars() {
        let longBody = String(repeating: "日", count: 200)
        let memo = Memo(id: UUID(), type: .text, created: Date(), body: longBody)
        provider.update(memos: [memo])
        let chips = provider.chips
        let snippet = chips.compactMap { if case .lastMemoTail(let s) = $0 { return s } else { return nil } }.first
        XCTAssertNotNil(snippet)
        XCTAssertLessThanOrEqual(snippet!.count, 60, "snippet must be at most 60 characters")
    }

    // MARK: - lastMemoTail 60s cache

    func testChips_lastMemoTail_cacheReturnsSameSnippet() {
        let memo = Memo(id: UUID(), type: .text, created: Date(), body: "cached content")
        provider.update(memos: [memo])
        let first = provider.chips.compactMap { if case .lastMemoTail(let s) = $0 { return s } else { return nil } }.first
        let second = provider.chips.compactMap { if case .lastMemoTail(let s) = $0 { return s } else { return nil } }.first
        XCTAssertEqual(first, second, "cache must return same snippet within 60s")
    }

    // MARK: - update clears cache

    func testChips_updateMemos_invalidatesCache() {
        let memo1 = Memo(id: UUID(), type: .text, created: Date(), body: "first memo body")
        provider.update(memos: [memo1])
        let first = provider.chips.compactMap { if case .lastMemoTail(let s) = $0 { return s } else { return nil } }.first

        let memo2 = Memo(id: UUID(), type: .text, created: Date(), body: "second memo body")
        provider.update(memos: [memo1, memo2])
        let second = provider.chips.compactMap { if case .lastMemoTail(let s) = $0 { return s } else { return nil } }.first

        XCTAssertNotEqual(first, second, "update(memos:) must invalidate the lastMemoTail cache")
    }

    // MARK: - timeRitual mapping

    func testTimeRitual_chip_hasEmojiAndText() {
        let chips = provider.chips
        let ritual = chips.compactMap { (chip: ContextChip) -> (String, String)? in
            if case .timeRitual(let e, let t) = chip { return (e, t) } else { return nil }
        }.first
        XCTAssertNotNil(ritual)
        XCTAssertFalse(ritual!.0.isEmpty, "timeRitual emoji must not be empty")
        XCTAssertFalse(ritual!.1.isEmpty, "timeRitual text must not be empty")
    }

    // MARK: - smartPaste absent when pasteboard empty

    func testChips_smartPaste_absentWhenPasteboardCleared() {
        UIPasteboard.general.string = nil
        let chips = provider.chips
        let hasPaste = chips.contains { if case .smartPaste = $0 { return true }; return false }
        XCTAssertFalse(hasPaste, "smartPaste chip must be absent when pasteboard has no string")
    }

    func testChips_smartPaste_presentWhenPasteboardHasContent() {
        UIPasteboard.general.string = "some copied text"
        defer { UIPasteboard.general.string = nil }
        let chips = provider.chips
        let pasteValue = chips.compactMap { if case .smartPaste(let v) = $0 { return v } else { return nil } }.first
        XCTAssertNotNil(pasteValue, "smartPaste chip must be present when pasteboard has a string")
        XCTAssertEqual(pasteValue, "some copied text")
    }

    func testChips_smartPaste_valueTruncatedTo100Chars() {
        let longString = String(repeating: "a", count: 200)
        UIPasteboard.general.string = longString
        defer { UIPasteboard.general.string = nil }
        let chips = provider.chips
        let pasteValue = chips.compactMap { if case .smartPaste(let v) = $0 { return v } else { return nil } }.first
        XCTAssertNotNil(pasteValue)
        XCTAssertLessThanOrEqual(pasteValue!.count, 100, "smartPaste value must be at most 100 characters")
    }
}
