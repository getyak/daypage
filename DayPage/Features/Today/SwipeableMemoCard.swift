import SwiftUI

// MARK: - SwipePhysics
//
// All numeric constants for the swipe-to-reveal interaction live here so the
// motion language is auditable in one place and easy to tune. Names are
// chosen to map to the four-stage gesture vocabulary:
//
//   peek      — finger moves but the action is not yet committable.
//   reveal    — the user has crossed the open threshold; icon + label sit on
//                a settled panel; releasing snaps the panel open.
//   rubber    — drag continues past the panel; resistance grows with distance.
//
// Tuned against Apple Mail / Notes / Reminders for snappy attack and minimal
// overshoot, while keeping the panel surface visually quiet at small offsets.
private enum SwipePhysics {

    /// Width of the action panel on each side. Widened toward the design's
    /// 132pt reveal (`DSTokens.Gestures.swipeRevealWidth`); 96pt keeps a single
    /// action reading as one comfortable tap target without over-revealing.
    static let panelWidth: CGFloat = 96

    /// Translation past which a release snaps open (vs. snap back closed).
    /// Apple Notes uses ~40pt; we follow the same ratio to panelWidth so a
    /// confident half-swipe always opens but a hesitant brush snaps back.
    static let openThreshold: CGFloat = 40

    /// Translation while open past which a release snaps closed. Lower than
    /// openThreshold because the user has already paid the gesture cost of
    /// opening — closing should feel lighter.
    static let closeThreshold: CGFloat = 24

    /// Velocity (pt/s) past which a flick alone opens the panel, regardless
    /// of translation. UIKit reports real velocity so we use the same
    /// numeric scale as iOS Mail (~600 pt/s).
    static let velocityOpen: CGFloat = 600

    /// Velocity past which a flick alone closes the panel.
    static let velocityClose: CGFloat = 500

    /// Resistance coefficient applied to drag past the panel edge. 0.25 is
    /// firmer than the previous 0.35 so the limit reads as a real wall while
    /// still allowing a tactile overdrag.
    static let rubberBand: CGFloat = 0.25

    /// Spring used for snap-open / snap-close. Same response as iOS Mail
    /// (~0.28s) with damping that lets the panel settle in one cycle.
    static let snapSpring: Animation = .spring(response: 0.28, dampingFraction: 0.86)

    /// Eased curve used in place of `snapSpring` when Reduce Motion is on.
    /// No bounce, slightly shorter so the user can still feel the commit.
    static let reducedSnap: Animation = .easeOut(duration: 0.22)
}

// MARK: - SwipeableMemoCard
//
// iOS-native swipe-to-reveal wrapper around MemoCardView, built on a UIKit
// UIPanGestureRecognizer (see HorizontalPanGesture.swift) so the parent
// ScrollView keeps full ownership of vertical drags. Mirrors iOS Mail,
// Reminders, and Things 3 swipe-to-reveal behavior, with iOS-26-flavored
// visual choreography: the action surface deepens in tone as the drag
// progresses, the icon scales up, and the label only resolves once the
// open threshold is crossed.
//
//  - Left swipe → trailing SHARE action (accent amber) — the prominent,
//    content-first action surfaced by the museum-aesthetic redesign.
//  - Right swipe → leading MORE action (sunken neutral) — opens the fuller
//    set (pin / delete / …) so secondary chrome stays hidden by default.
//
// Gesture model:
//  - settledOffset is the resting position; dragDelta rides on top 1:1.
//  - Rubber-band resistance beyond ±panelW gives tactile limit feedback.
//  - Velocity-aware snap: a flick opens/closes even with small translation.
//  - Threshold-cross haptic tick fires during the drag (not just at button
//    tap), matching the Apple Notes "you've armed an action" feel.
//
// Why no SwiftUI DragGesture: SwiftUI's DragGesture + simultaneousGesture
// activates on the very first touch event and cannot relinquish gesture
// ownership back to UIScrollView. That broke vertical timeline scrolling
// whenever a finger landed on a card. The UIKit recognizer's
// gestureRecognizerShouldBegin gate is the only correct way to express
// "stay pending until direction is confirmed."
struct SwipeableMemoCard: View {

    let memo: Memo
    var onDelete: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil
    /// Left-swipe SHARE action (museum-aesthetic primary).
    var onShare: (() -> Void)? = nil
    /// Right-swipe MORE action — parent presents the fuller action set.
    var onMore: (() -> Void)? = nil
    var onRetranscribe: ((Memo, Memo.Attachment) -> Void)? = nil
    /// Issue #309 W2: in multi-select mode, both the NavigationLink tap
    /// and the swipe gesture must be inert — the only valid interaction is
    /// the tap-to-toggle handled by the parent TimelineRow. Both panels
    /// are also auto-closed when entering this mode.
    var isSelectionMode: Bool = false

    // Settled resting offset: -panelW = trailing open, 0 = closed, +panelW = leading open
    @State private var settledOffset: CGFloat = 0

    // Live horizontal translation from the active UIKit pan. Distinct from
    // settledOffset so we can apply rubber-band on the sum without losing
    // either piece of state mid-drag.
    @State private var dragDelta: CGFloat = 0

    // True while UIPanGestureRecognizer is in began/changed. Used to disable
    // the NavigationLink so the tap that fires on lift after a real swipe
    // never routes to the detail page.
    @State private var isPanActive: Bool = false

    // Tracks which threshold the live drag has already crossed so the
    // mid-drag haptic tick fires once per cross, not once per frame.
    @State private var armedSide: Side? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate enum Side { case leading, trailing }

    private var revealedSide: Side? {
        if settledOffset < -1 { return .trailing }
        if settledOffset > 1  { return .leading }
        return nil
    }

    private var currentOffset: CGFloat {
        let raw = settledOffset + dragDelta
        let w = SwipePhysics.panelWidth
        if raw > w  { return w  + (raw - w)  * SwipePhysics.rubberBand }
        if raw < -w { return -w + (raw + w)  * SwipePhysics.rubberBand }
        return raw
    }

    /// Normalized reveal progress used by the panel choreography. Positive
    /// when the leading (right-swipe → pin) panel is being revealed and
    /// negative for the trailing (left-swipe → delete) panel. Lightly
    /// over-clamped at ±1.4 so a small rubber-band overdrag still nudges
    /// scale/opacity without blowing them out.
    private var revealProgress: CGFloat {
        let p = currentOffset / SwipePhysics.panelWidth
        return max(-1.4, min(1.4, p))
    }

    private var accessibilityMemoLabel: String {
        let prefix = memo.body.prefix(50)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Memo" : "Memo: \(trimmed)"
    }

    private var snapAnimation: Animation {
        reduceMotion ? SwipePhysics.reducedSnap : SwipePhysics.snapSpring
    }

    var body: some View {
        ZStack(alignment: .center) {
            // Action surfaces sit behind the card. Each is clipped to the
            // card's outer corner radius so the panel reads as a nested
            // glass surface rather than an abutting colored rectangle.
            HStack(spacing: 0) {
                SwipeActionPanel(
                    kind: .more,
                    progress: max(0, revealProgress),
                    onTap: handleMoreTap
                )
                Spacer(minLength: 0)
                SwipeActionPanel(
                    kind: .share,
                    progress: max(0, -revealProgress),
                    onTap: handleShareTap
                )
            }

            NavigationLink(value: memo.id) {
                MemoCardView(memo: memo, onDelete: onDelete)
            }
            .buttonStyle(.plain)
            // Disable the NavigationLink while a horizontal pan is active or
            // a side panel is open. UIKit already cancels its own tap chain
            // when our pan begins, but SwiftUI's NavigationLink uses a
            // separate recognizer that this explicit guard catches.
            .disabled(revealedSide != nil || isPanActive || isSelectionMode)
            .offset(x: isSelectionMode ? 0 : currentOffset)
            // UIKit pan attached as a background layer. PassthroughView
            // returns nil from hitTest, so taps and vertical drags fall
            // through unimpeded — only when shouldBegin confirms a
            // horizontal pan does this layer claim the touch and the
            // surrounding UIScrollView's pan get cancelled by UIKit's
            // standard arbitration. This is the entire reason we ditched
            // SwiftUI DragGesture + simultaneousGesture.
            .background(
                HorizontalPanGesture(
                    isActive: $isPanActive,
                    onChanged: handlePanChanged,
                    onEnded: handlePanEnded,
                    onCancelled: handlePanCancelled,
                    isEnabled: !isSelectionMode
                )
            )

            // Invisible tap/drag-to-close overlay: only active when a panel
            // is open. Lives above the card so it intercepts both taps and
            // drags independently of `.disabled` on the NavigationLink.
            if revealedSide != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { snapClose() }
                    .background(
                        HorizontalPanGesture(
                            isActive: $isPanActive,
                            onChanged: handlePanChanged,
                            onEnded: handlePanEnded,
                            onCancelled: handlePanCancelled,
                            isEnabled: true
                        )
                    )
            }
        }
        .clipped()
        .accessibilityLabel(accessibilityMemoLabel)
        .accessibilityAction(named: "Share") { onShare?() }
        .accessibilityAction(named: "More") { onMore?() }
        .accessibilityAction(named: "Delete") { onDelete?() }
        .accessibilityAction(named: memo.pinnedAt != nil ? "Unpin" : "Pin") { onPin?() }
        // Entering selection mode mid-swipe (panel revealed) would leave a
        // dangling open panel that the user can't close — selection-mode
        // gestures don't reach the close overlay. Force-close on transition
        // so the card is visually flush when selection chrome appears.
        .onChange(of: isSelectionMode) { newValue in
            if newValue, revealedSide != nil {
                snapClose()
            }
        }
    }

    // MARK: - Action handlers

    private func handleShareTap() {
        Haptics.tapConfirm()
        snapClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onShare?() }
    }

    private func handleMoreTap() {
        Haptics.soft()
        snapClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onMore?() }
    }

    // MARK: - Pan callbacks
    //
    // The UIKit recognizer handles direction-lock and slop before these
    // fire; by the time onChanged runs, the touch is already confirmed
    // horizontal and we can apply translation 1:1.

    private func handlePanChanged(_ translation: CGFloat) {
        dragDelta = translation
        updateThresholdHaptics()
    }

    private func handlePanEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        dragDelta = 0
        decideSnap(dx: translation, velocity: velocity)
        armedSide = nil
    }

    private func handlePanCancelled() {
        // Snap back to the prior resting state without touching settledOffset.
        dragDelta = 0
        armedSide = nil
    }

    /// Fires a soft tick the first time a drag crosses the open threshold
    /// in each direction. Subsequent frames inside the same band don't
    /// re-trigger. Mirrors the Apple Notes "armed" feedback that tells the
    /// user "release now and the action will fire."
    private func updateThresholdHaptics() {
        let offset = currentOffset
        let armingSide: Side?
        if offset > SwipePhysics.openThreshold {
            armingSide = .leading
        } else if offset < -SwipePhysics.openThreshold {
            armingSide = .trailing
        } else {
            armingSide = nil
        }
        if armingSide != armedSide {
            armedSide = armingSide
            if armingSide != nil { Haptics.soft() }
        }
    }

    // MARK: - Snap Logic
    //
    // dx is always relative to the drag start position (not screen zero).
    // When trailing panel is open (settledOffset = -panelW), a rightward drag
    // produces dx > 0, which correctly triggers snapClose via the first branch.
    // No coordinate transform needed — this is the fix for the "can't close" bug.

    private func decideSnap(dx: CGFloat, velocity: CGFloat) {
        let openT = SwipePhysics.openThreshold
        let closeT = SwipePhysics.closeThreshold
        let vOpen = SwipePhysics.velocityOpen
        let vClose = SwipePhysics.velocityClose
        switch revealedSide {
        case nil:
            if      dx < -openT || velocity < -vOpen  { snapOpen(.trailing) }
            else if dx >  openT || velocity >  vOpen  { snapOpen(.leading)  }
            else                                       { snapClose()         }
        case .trailing:
            (dx > closeT || velocity > vClose) ? snapClose() : snapOpen(.trailing)
        case .leading:
            (dx < -closeT || velocity < -vClose) ? snapClose() : snapOpen(.leading)
        }
    }

    private func snapOpen(_ side: Side) {
        let target: CGFloat = side == .trailing ? -SwipePhysics.panelWidth : SwipePhysics.panelWidth
        withAnimation(snapAnimation) { settledOffset = target }
        HapticFeedback.light()
    }

    func snapClose() {
        withAnimation(snapAnimation) { settledOffset = 0 }
    }
}

// MARK: - SwipeActionPanel
//
// Visual surface for one side of the swipe action drawer. Sits behind the
// card and is clipped to the card's 18pt outer corner radius via the
// surrounding `.clipped()` on the ZStack, so the panel reads as a nested
// glass surface rather than a bright abutting rectangle.
//
// Choreography (driven by `progress`, 0…1+):
//
//   0.00 – 0.30   Icon at 0.6× scale, label hidden, soft tone.
//   0.30 – 1.00   Icon grows to 1.0×, label fades in, tone deepens.
//
// The button is a full-bleed tap target so a user who has revealed the
// panel can hit it without precise aim — matches Apple Mail / Notes.
private struct SwipeActionPanel: View {

    enum Kind {
        case more   // right-swipe (leading) — sunken neutral
        case share  // left-swipe (trailing) — accent amber
    }

    let kind: Kind
    let progress: CGFloat
    let onTap: () -> Void

    // Choreography breakpoints
    private let labelFadeStart: CGFloat = 0.30
    private let iconScaleMin: CGFloat = 0.6
    private let iconScaleMax: CGFloat = 1.0

    var body: some View {
        Button(action: onTap) {
            ZStack {
                background
                content
            }
            .frame(width: SwipePhysics.panelWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hide entirely when fully closed so VoiceOver doesn't announce a
        // tap target the user can't see, and disable hit testing so a
        // stray tap on the (still-laid-out) panel behind the card doesn't
        // route into the action when the panel is meant to be invisible.
        .opacity(progress > 0.02 ? 1 : 0)
        .allowsHitTesting(progress > 0.02)
        .accessibilityHidden(progress <= 0.02)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Subviews

    private var background: some View {
        // Liquid Glass: a frosted .ultraThinMaterial base with the brand color
        // layered as a translucent tint that deepens as the panel is revealed,
        // rather than a flat opaque fill. The material refracts the warm vault
        // background behind it, so the action drawer reads as a nested glass
        // surface waking up. MORE's sunken neutral keeps a higher tint floor so
        // its pale surface stays legible against the card.
        let floor: CGFloat = (kindIsMore ? 0.78 : 0.42)
        let tint = Double(floor + (1 - floor) * min(1, progress))
        return ZStack {
            Rectangle().fill(.ultraThinMaterial)
            baseColor.opacity(tint)
        }
    }

    private var kindIsMore: Bool {
        if case .more = kind { return true }
        return false
    }

    private var content: some View {
        VStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(foreground)
                .scaleEffect(iconScale)

            Text(label)
                .font(.custom("Inter-Medium", size: 11))
                .foregroundColor(foreground)
                .opacity(labelOpacity)
        }
    }

    // MARK: - Visual derivations

    private var iconName: String {
        switch kind {
        case .more:  return "ellipsis"
        case .share: return "square.and.arrow.up"
        }
    }

    private var label: String {
        switch kind {
        case .more:  return "更多"
        case .share: return "分享"
        }
    }

    /// MORE rides on a sunken neutral surface (dark ink), SHARE on accent amber
    /// (white ink) — the design's content-first hierarchy.
    private var baseColor: Color {
        switch kind {
        case .more:  return DSColor.surfaceSunken
        case .share: return DSColor.accentAmber
        }
    }

    private var foreground: Color {
        switch kind {
        case .more:  return DSColor.inkPrimary
        case .share: return .white
        }
    }

    private var iconScale: CGFloat {
        let clamped = max(0, min(1, progress))
        return iconScaleMin + (iconScaleMax - iconScaleMin) * clamped
    }

    private var labelOpacity: Double {
        let clamped = max(0, min(1, (progress - labelFadeStart) / (1 - labelFadeStart)))
        return Double(clamped)
    }

    private var accessibilityLabel: String {
        switch kind {
        case .more:  return "More actions"
        case .share: return "Share memo"
        }
    }
}
