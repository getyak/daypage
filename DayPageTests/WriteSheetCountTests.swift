import Testing
@testable import DayPage

struct WriteSheetCountTests {

    @Test func chineseSentence() {
        // Each ideograph is one word
        #expect(WriteSheetView.wordCount(in: "今天天气很好") == 6)
    }

    @Test func latinWords() {
        #expect(WriteSheetView.wordCount(in: "hello world") == 2)
    }

    @Test func mixedCJKAndLatin() {
        // "I love 北京 city" → I(1) love(2) 北(3) 京(4) city(5)
        #expect(WriteSheetView.wordCount(in: "I love 北京 city") == 5)
    }

    @Test func emptyString() {
        #expect(WriteSheetView.wordCount(in: "") == 0)
    }

    @Test func whitespaceOnly() {
        #expect(WriteSheetView.wordCount(in: "   \t\n  ") == 0)
    }

    @Test func hiragana() {
        // Each hiragana character counts as one word
        #expect(WriteSheetView.wordCount(in: "あいう") == 3)
    }

    @Test func katakana() {
        // Each katakana character counts as one word
        #expect(WriteSheetView.wordCount(in: "アイウ") == 3)
    }

    @Test func mixedRunsAdjacentNoBoundary() {
        // hello (1 Latin run) + 北 (1) + 京 (1) = 3, even without spaces
        #expect(WriteSheetView.wordCount(in: "hello北京") == 3)
    }
}
