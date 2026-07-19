import SwiftUI

// MARK: - Today scroll / transition modifiers
//
// Extracted from TodayView.swift (#16 密度收敛): pure ViewModifiers and the
// scroll-offset PreferenceKey used by TodayView. All are availability-gated
// self-contained wrappers (iOS 17 scroll entrance / numericText, iOS 18 card
// zoom hero) with no coupling to TodayView state — moved out verbatim.

// US-005: PreferenceKey used to propagate the ScrollView offset up to TodayView.
// (Was `private` when it lived inside TodayView.swift; now file-external so it
// needs at least internal visibility for TodayView to reference it.)
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Delivers the Today timeline's scroll offset to `handleScrollOffset`.
///
/// Canvas vNext (2026-07-14): on iOS 18+ the classic GeometryReader →
/// PreferenceKey pattern stopped firing during scrolls (verified on the
/// iOS 26.1 simulator via app.log instrumentation: the callback ran exactly
/// once at initial layout, then never again — scrolling no longer re-runs
/// content layout, so the preference never republishes). That silently
/// killed every offset-driven surface: glass header, scroll-to-top ring,
/// and the new hero recede. On iOS 18+ we read `onScrollGeometryChange`
/// instead; iOS 16–17 keep the preference path, which still works there.
///
/// Value convention (both paths): 0 at rest, NEGATIVE as the user scrolls
/// up — the historical minY convention TodayView's thresholds are written
/// against.
struct TodayScrollOffsetWatcher: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, newValue in
                onChange(newValue)
            }
        } else {
            content.onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                onChange(value)
            }
        }
    }
}

// MARK: - Scroll entrance (iOS 17+)

/// 美术馆入场: timeline memo cards settle in as they scroll into the
/// viewport — rows just outside the visible region fade up from 82% opacity
/// to identity. Deliberately subtle: the timeline is a quiet gallery wall,
/// not a showcase. iOS 16 and Reduce Motion pass the content through
/// unmodified. Applied to the row container that wraps SwipeableMemoCard
/// (never inside it) so the phase transform cannot fight the card's UIKit
/// pan + offset swipe-to-reveal.
///
/// Performance (2026-07-19, §4 scroll polish): the entrance used to also
/// interpolate `scaleEffect(0.985→1)` every frame. A per-frame `scaleEffect`
/// on every near-edge row forces an off-screen composite buffer per card,
/// which was the single largest recurring cost on the scroll path (confirmed
/// by the timeline perf audit). The scale delta was 1.5% — optically
/// imperceptible — so it's dropped entirely. Opacity stays: a `.interactive`
/// opacity ramp is cheap (a layer alpha, no off-screen pass) and keeps the
/// settle-in feel that reads as "quiet gallery". The rest opacity is nudged
/// 0.72→0.82 so, without the scale cue, the fade alone still feels gentle
/// rather than a hard flicker.
struct ScrollEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *), !reduceMotion {
            content.scrollTransition(.interactive(timingCurve: .easeOut), axis: .vertical) { view, phase in
                view.opacity(phase.isIdentity ? 1 : 0.82)
            }
        } else {
            content
        }
    }
}

// ViewModifier to wrap .numericText(value:) which requires iOS 17+.
// (Was a file-private copy inside TodayView.swift — one of three identical
// copies across Today/Search/Graph. Extracted here it needs internal
// visibility, so it's renamed `TodayNumericTextTransition` to stay distinct
// from the still-private Search/Graph copies rather than forcing a repo-wide
// dedup inside this file-split refactor.)
struct TodayNumericTextTransition: ViewModifier {
    let value: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .contentTransition(reduceMotion ? .identity : .numericText(value: value))
        } else {
            content
                .contentTransition(.identity)
        }
    }
}

// MARK: - Card → Detail zoom transition (iOS 18+)
//
// The App Store / Photos-style hero: tapping a memo card zooms the detail
// page out of the card frame and the back-swipe shrinks it back in. Both
// halves must share one `Namespace` (owned by TodayView) and matching ids.
// On iOS 16–17 both modifiers are inert and navigation keeps the standard
// push — no behavioral change below the availability floor.

/// Marks a timeline card as the zoom source for `memo.id`.
// `ID` is generic over `Hashable` so this works for both the memo cards
// (keyed by `UUID`) and the historical-day entries (keyed by the `yyyy-MM-dd`
// date string). `matchedTransitionSource(id:)` accepts any Hashable identity.
struct CardZoomSource<ID: Hashable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// Applies the zoom navigation transition to the pushed detail page.
struct CardZoomDestination<ID: Hashable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}
