import SwiftUI

// MARK: - SwipeableMemoCard
//
// iOS-native swipe-to-reveal wrapper around MemoCardView, built on a UIKit
// UIPanGestureRecognizer (see HorizontalPanGesture.swift) so the parent
// ScrollView keeps full ownership of vertical drags. Mirrors iOS Mail,
// Reminders, and Things 3 swipe-to-reveal behavior.
//
//  - Left swipe → trailing Delete button
//  - Right swipe → leading Pin button
//
// Gesture model:
//  - settledOffset is the resting position; dragDelta rides on top 1:1.
//  - Rubber-band resistance beyond ±panelW gives tactile limit feedback.
//  - Velocity-aware snap: a flick opens/closes even with small translation.
//  - snapClose is always reachable: when trailing is open, any rightward
//    drag or flick collapses it (dx is relative to drag start).
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

    private enum Side { case leading, trailing }

    private var revealedSide: Side? {
        if settledOffset < -1 { return .trailing }
        if settledOffset > 1  { return .leading }
        return nil
    }

    private let panelW: CGFloat         = 80
    private let openThreshold: CGFloat  = 40
    private let closeThreshold: CGFloat = 24
    // UIKit reports real velocity in pt/s; flick thresholds raised accordingly.
    private let velOpen: CGFloat        = 600
    private let velClose: CGFloat       = 500

    // Rubber-band resistance when dragging past the panel edge
    private let rubberBand: CGFloat = 0.35

    private var currentOffset: CGFloat {
        let raw = settledOffset + dragDelta
        if raw > panelW  { return panelW  + (raw - panelW)  * rubberBand }
        if raw < -panelW { return -panelW + (raw + panelW)  * rubberBand }
        return raw
    }

    private var accessibilityMemoLabel: String {
        let prefix = memo.body.prefix(50)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Memo" : "Memo: \(trimmed)"
    }

    var body: some View {
        ZStack(alignment: .center) {
            HStack(spacing: 0) {
                pinPanel
                Spacer()
                deletePanel
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

    // MARK: - Panels

    private var pinPanel: some View {
        Button(action: {
            Haptics.tapConfirm()
            snapClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onPin?() }
        }) {
            VStack(spacing: 4) {
                Image(systemName: memo.pinnedAt != nil ? "pin.slash.fill" : "pin.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(memo.pinnedAt != nil ? "取消置顶" : "置顶")
                    .font(.custom("Inter-Medium", size: 11))
            }
            .foregroundColor(.white)
            .frame(width: panelW)
            .frame(maxHeight: .infinity)
            .background(memo.pinnedAt != nil ? DSColor.secondary : DSColor.amberArchival)
        }
        .opacity(revealedSide == .leading ? 1 : 0)
    }

    private var deletePanel: some View {
        Button(action: {
            Haptics.warn()
            snapClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onDelete?() }
        }) {
            VStack(spacing: 4) {
                Image(systemName: "trash.fill").font(.system(size: 16, weight: .semibold))
                Text("删除").font(.custom("Inter-Medium", size: 11))
            }
            .foregroundColor(.white)
            .frame(width: panelW)
            .frame(maxHeight: .infinity)
            .background(DSColor.error)
        }
        .opacity(revealedSide == .trailing ? 1 : 0)
    }

    // MARK: - Pan callbacks
    //
    // The UIKit recognizer handles direction-lock and slop before these
    // fire; by the time onChanged runs, the touch is already confirmed
    // horizontal and we can apply translation 1:1.

    private func handlePanChanged(_ translation: CGFloat) {
        dragDelta = translation
    }

    private func handlePanEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        dragDelta = 0
        decideSnap(dx: translation, velocity: velocity)
    }

    private func handlePanCancelled() {
        // Snap back to the prior resting state without touching settledOffset.
        dragDelta = 0
    }

    // MARK: - Snap Logic
    //
    // dx is always relative to the drag start position (not screen zero).
    // When trailing panel is open (settledOffset = -panelW), a rightward drag
    // produces dx > 0, which correctly triggers snapClose via the first branch.
    // No coordinate transform needed — this is the fix for the "can't close" bug.

    private func decideSnap(dx: CGFloat, velocity: CGFloat) {
        switch revealedSide {
        case nil:
            if      dx < -openThreshold || velocity < -velOpen  { snapOpen(.trailing) }
            else if dx >  openThreshold || velocity >  velOpen  { snapOpen(.leading)  }
            else                                                 { snapClose()         }
        case .trailing:
            // Open to left → rightward drag (dx > 0) or rightward flick closes
            (dx > closeThreshold || velocity > velClose) ? snapClose() : snapOpen(.trailing)
        case .leading:
            // Open to right → leftward drag (dx < 0) or leftward flick closes
            (dx < -closeThreshold || velocity < -velClose) ? snapClose() : snapOpen(.leading)
        }
    }

    // Spring tuned to iOS Mail / Reminders: snappy attack, minimal overshoot
    private var snapSpring: Animation {
        .spring(response: 0.28, dampingFraction: 0.86)
    }

    private func snapOpen(_ side: Side) {
        let target: CGFloat = side == .trailing ? -panelW : panelW
        withAnimation(snapSpring) { settledOffset = target }
        HapticFeedback.light()
    }

    func snapClose() {
        withAnimation(snapSpring) { settledOffset = 0 }
    }
}
