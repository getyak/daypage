import Testing
import Foundation
@testable import DayPage

@Suite("SearchHighlight")
struct SearchHighlightTests {

    // MARK: - foldedForSearch helper

    @Test("folding 'cafe' matches 'Café'")
    func foldCafeMatchesCafe() {
        let folded = SearchView.foldedForSearchTesting("Café")
        let keyword = SearchView.foldedForSearchTesting("cafe")
        #expect(folded.contains(keyword))
    }

    @Test("folding is case-insensitive")
    func foldCaseInsensitive() {
        let folded = SearchView.foldedForSearchTesting("Hello World")
        let keyword = SearchView.foldedForSearchTesting("hello world")
        #expect(folded.contains(keyword))
    }

    @Test("folding is diacritic-insensitive")
    func foldDiacriticInsensitive() {
        let folded = SearchView.foldedForSearchTesting("naïve résumé")
        let keyword = SearchView.foldedForSearchTesting("naive resume")
        #expect(folded.contains(keyword))
    }

    @Test("folding is width-insensitive for full-width ASCII")
    func foldWidthInsensitive() {
        // Full-width 'Ａ' (U+FF21) should fold to 'a'
        let fullWidth = "\u{FF21}\u{FF22}\u{FF23}" // ＡＢＣ
        let folded = SearchView.foldedForSearchTesting(fullWidth)
        let keyword = SearchView.foldedForSearchTesting("abc")
        #expect(folded.contains(keyword))
    }

    // MARK: - Highlight range for accented match

    @Test("'cafe' produces a highlight range in 'Visited the Café'")
    func highlightCafeInCafe() {
        let text = "Visited the Café"
        let keyword = "cafe"

        let foldedText = SearchView.foldedForSearchTesting(text)
        let foldedKeyword = SearchView.foldedForSearchTesting(keyword)

        // The folded text should contain the folded keyword
        #expect(foldedText.contains(foldedKeyword))

        // And the match range should resolve to a non-nil range (highlight will be applied)
        let matchRange = foldedText.range(of: foldedKeyword)
        #expect(matchRange != nil)

        // The character offset should be 12 (after "Visited the ")
        if let range = matchRange {
            let offset = foldedText.distance(from: foldedText.startIndex, to: range.lowerBound)
            #expect(offset == 12)
        }
    }

    @Test("ASCII keyword still produces a highlight range")
    func highlightAsciiKeyword() {
        let text = "Took the train to Berlin"
        let keyword = "berlin"

        let foldedText = SearchView.foldedForSearchTesting(text)
        let foldedKeyword = SearchView.foldedForSearchTesting(keyword)

        let matchRange = foldedText.range(of: foldedKeyword)
        #expect(matchRange != nil)
    }

    @Test("no match returns nil range — fallback intact")
    func noMatchReturnsNil() {
        let text = "Nothing relevant here"
        let keyword = "café"

        let foldedText = SearchView.foldedForSearchTesting(text)
        let foldedKeyword = SearchView.foldedForSearchTesting(keyword)

        let matchRange = foldedText.range(of: foldedKeyword)
        #expect(matchRange == nil)
    }
}
