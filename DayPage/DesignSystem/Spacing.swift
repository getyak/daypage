import SwiftUI

// MARK: - DSSpacing
//
// 4 / 8 pt rhythm (Material spacing + Apple HIG hybrid). Use the numeric
// scale (xs…5xl) for raw padding/gap values, and the semantic aliases
// (pageMargin / cardInner / cardGap / sectionGap / dockGap) for layout
// intent. New code SHOULD prefer the semantic aliases — when the design
// brief shifts, only the alias mapping needs to change.

enum DSSpacing {

    // MARK: - Numeric scale (4 / 8 pt)

    /// 4 pt — hairline gaps inside a single component.
    static let xs:  CGFloat = 4
    /// 8 pt — tight grouping (icon ↔ label, chip inner padding).
    static let sm:  CGFloat = 8
    /// 12 pt — row vertical padding, chip outer gap.
    static let md:  CGFloat = 12
    /// 16 pt — card-internal gap, default content gutter on small layouts.
    static let lg:  CGFloat = 16
    /// 20 pt — page horizontal margin (`pageMargin`).
    static let xl:  CGFloat = 20
    /// 24 pt — section vertical gap.
    static let xl2: CGFloat = 24
    /// 32 pt — major section break.
    static let xl3: CGFloat = 32
    /// 48 pt — hero block padding.
    static let xl4: CGFloat = 48
    /// 64 pt — top-of-screen breathing room (e.g. Sidebar brand header).
    static let xl5: CGFloat = 64

    // MARK: - Semantic aliases (preferred in new code)

    /// Default horizontal page margin (left/right of timeline content).
    static let pageMargin: CGFloat = xl       // 20
    /// Padding inside a card surface (between rim and content).
    static let cardInner:  CGFloat = xl       // 20
    /// Vertical gap between adjacent cards in a list.
    static let cardGap:    CGFloat = lg       // 16
    /// Vertical gap between two distinct sections on the same screen.
    static let sectionGap: CGFloat = xl2      // 24
    /// Vertical gap between the timeline and the composer dock.
    static let dockGap:    CGFloat = md       // 12
    /// Spacing between an icon and its label.
    static let iconLabel:  CGFloat = sm       // 8
    /// Bottom safe-area cushion above the home indicator.
    static let bottomDock: CGFloat = lg       // 16

    // MARK: - Legacy aliases (kept for compile compatibility — DO NOT use in new code)

    /// - Deprecated: Use `DSRadius.lg`.
    static let radiusCard: CGFloat = 12
    /// - Deprecated: Use `DSRadius.sm`.
    static let radiusSmall: CGFloat = 8
}
