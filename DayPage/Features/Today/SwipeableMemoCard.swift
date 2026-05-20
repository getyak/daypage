import SwiftUI

// MARK: - SwipeableMemoCard

/// iOS-native swipe-to-reveal wrapper around MemoCardView.
/// Left swipe → trailing Delete button. Right swipe → leading Pin button.
///
/// Gesture model mirrors iOS Mail / Reminders:
///  - settledOffset is the resting position; dragDelta rides on top 1:1
///  - Rubber-band resistance beyond ±panelW gives tactile limit feedback
///  - Velocity-aware snap: flick opens/closes even with small translation
///  - snapClose is always reachable: when trailing is open, any rightward
///    drag or flick collapses it (dx is relative to drag start, not screen zero)
///  - When a panel is revealed, the underlying NavigationLink is disabled,
///    which also blocks its `.highPriorityGesture`. The Color.clear overlay
///    therefore re-attaches the same swipeGesture so drag-to-close keeps
///    working while a panel is open (the overlay also handles tap-to-close).
struct SwipeableMemoCard: View {

    let memo: Memo
    var onDelete: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil
    var onRetranscribe: ((Memo, Memo.Attachment) -> Void)? = nil

    // Settled resting offset: -panelW = trailing open, 0 = closed, +panelW = leading open
    @State private var settledOffset: CGFloat = 0

    // Combined gesture state.
    //
    // `delta` is the live horizontal translation that rides on top of
    // settledOffset (the visible card offset).
    //
    // `moved` is true once the finger has moved past touchSlop in any
    // direction. It disables the NavigationLink mid-touch so that finger-up
    // after a near-vertical drag, a sub-threshold horizontal swipe, or a
    // pure ScrollView pan no longer mis-routes into the memo detail page.
    //
    // Both live in a single GestureState tuple so they are guaranteed to
    // update from the same .updating callback and reset together when the
    // gesture ends (GestureState reset is automatic — no race with view
    // rebuilds).
    //
    // Why we need `moved`: the swipe DragGesture sits on the same view tree
    // as NavigationLink via .simultaneousGesture. SwiftUI's internal tap
    // recognizer inside NavigationLink does not respect our horizontal-
    // dominance guard — to it, any press-and-release is a tap. We have to
    // disable the link before it sees the up event.
    @GestureState private var drag: (delta: CGFloat, moved: Bool) = (0, false)

    private var dragDelta: CGFloat { drag.delta }
    private var isDraggingTouch: Bool { drag.moved }

    private enum Side { case leading, trailing }

    private var revealedSide: Side? {
        if settledOffset < -1 { return .trailing }
        if settledOffset > 1  { return .leading }
        return nil
    }

    private let panelW: CGFloat         = 80
    private let openThreshold: CGFloat  = 40
    private let closeThreshold: CGFloat = 24
    private let velOpen: CGFloat        = 250
    private let velClose: CGFloat       = 180

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
            // Disable the NavigationLink while a touch is being dragged or a
            // side panel is open. Disabling the link makes its internal tap
            // recognizer inert, so finger-up after a near-vertical scroll or
            // a sub-threshold horizontal swipe no longer mis-routes into the
            // memo detail page. Without this guard, simultaneousGesture lets
            // both the swipe and the NavigationLink tap fire from the same
            // touch sequence.
            .disabled(revealedSide != nil || isDraggingTouch)
            .offset(x: currentOffset)
            // simultaneousGesture (not highPriorityGesture): the parent
            // ScrollView must keep ownership of vertical drags. highPriority
            // locks gesture ownership on first touch — even with a direction
            // guard in .updating, ScrollView never gets a chance to claim a
            // vertical swipe, so the timeline freezes on tall voice memo
            // cards. simultaneous lets both recognizers see the touch; the
            // .updating closure below filters to horizontal-dominant deltas.
            //
            // drawingGroup removed: it forced Metal offscreen rasterization
            // on every Timer-driven waveform progress tick (0.1 s) while a
            // voice memo was playing — compounding scroll jank instead of
            // improving it.
            .simultaneousGesture(swipeGesture)

            // Invisible tap/drag-to-close overlay: only active when a panel is open.
            // Lives above the card so it intercepts both taps and drags
            // independently of `.disabled` on the NavigationLink (which would
            // otherwise swallow gestures attached to the disabled subtree).
            // When a panel is already revealed, horizontal interaction is the
            // expected mode, so highPriority is appropriate here.
            if revealedSide != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { snapClose() }
                    .highPriorityGesture(swipeGesture)
            }
        }
        .clipped()
        .accessibilityLabel(accessibilityMemoLabel)
        .accessibilityAction(named: "Delete") { onDelete?() }
        .accessibilityAction(named: memo.pinnedAt != nil ? "Unpin" : "Pin") { onPin?() }
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

    // MARK: - Gesture

    // Direction & activation thresholds.
    //
    // touchSlop 4: once a finger has moved at least 4 pt in any direction,
    // we treat the interaction as a drag, not a tap. This is what disables
    // the NavigationLink mid-touch so finger-up doesn't mis-route. 4 pt
    // matches UIKit's UIScrollView pan slop and is below the iOS tap
    // tolerance (~10 pt for system tap recognizers), so legitimate taps —
    // which barely move — still register.
    //
    // swipeMinDistance 12: |dx| must reach this before we actually start
    // translating the card. Lower values made the card visibly tug during
    // brief touches.
    //
    // horizontalDominance 1.5: |dx| must be 1.5× |dy| before we treat the
    // touch as a horizontal swipe (≈56° from vertical). Shallower drags
    // are forwarded to the parent ScrollView (see simultaneousGesture).
    private static let touchSlop: CGFloat = 4
    private static let swipeMinDistance: CGFloat = 12
    private static let horizontalDominance: CGFloat = 1.5

    private var swipeGesture: some Gesture {
        // minimumDistance 0 so .updating fires from the very first move
        // event — we need the chance to flip `moved` to true before
        // NavigationLink's internal tap recognizer can fire on touch-up.
        // The touchSlop guard inside the closure filters out finger-press-
        // without-movement so genuine taps still register.
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($drag) { value, state, _ in
                let dx = value.translation.width
                let dy = value.translation.height
                let exceededSlop = abs(dx) > Self.touchSlop || abs(dy) > Self.touchSlop
                let isHorizontalSwipe =
                    abs(dx) > Self.swipeMinDistance &&
                    abs(dx) > abs(dy) * Self.horizontalDominance
                state = (
                    delta: isHorizontalSwipe ? dx : 0,
                    moved: exceededSlop
                )
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > Self.swipeMinDistance,
                      abs(dx) > abs(dy) * Self.horizontalDominance else { return }
                let vel = value.predictedEndTranslation.width - value.translation.width
                decideSnap(dx: dx, velocity: vel)
            }
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
