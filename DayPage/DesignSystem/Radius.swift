import SwiftUI

// MARK: - DSRadius
//
// Continuous-curve corner radii. Liquid Glass surfaces default to `lg` (18 pt)
// — the same value LiquidGlassCard has been using inline. Pill shapes use
// `pill` (999) so a SwiftUI `RoundedRectangle(cornerRadius: DSRadius.pill)`
// renders as a fully-rounded capsule.

enum DSRadius {
    /// 6 pt — tags, mono-style data chips.
    static let xs:   CGFloat = 6
    /// 10 pt — small input fields, secondary chips.
    static let sm:   CGFloat = 10
    /// 14 pt — banners, location-draft card, small sheets.
    static let md:   CGFloat = 14
    /// 18 pt — primary Liquid Glass card (matches LiquidGlassCard default).
    static let lg:   CGFloat = 18
    /// 22 pt — elevated panels, expanded menus.
    static let xl:   CGFloat = 22
    /// 999 — fully rounded capsule (pills, action chips).
    static let pill: CGFloat = 999
}
