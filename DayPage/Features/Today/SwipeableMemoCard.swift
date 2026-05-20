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

    // Live drag translation applied on top of settledOffset
    @GestureState private var dragDelta: CGFloat = 0

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
            .disabled(revealedSide != nil)
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

    // Direction filter constants.
    //
    // minimumDistance 12: large enough that brief taps and the start of a
    // vertical scroll don't register as a horizontal swipe attempt. 8 was
    // too eager — paired with simultaneousGesture below, ScrollView still
    // wins vertical gestures, but a higher threshold keeps casual touches
    // from briefly tugging the card.
    //
    // horizontalDominance 1.5: |dx| must be 1.5× |dy| before we treat the
    // touch as a horizontal swipe. The previous 0.85 ratio meant a 45° drag
    // would still pull the card sideways, fighting vertical scrolling. 1.5
    // corresponds to roughly 56° from vertical — gestures shallower than
    // that are forwarded to ScrollView.
    private static let swipeMinDistance: CGFloat = 12
    private static let horizontalDominance: CGFloat = 1.5

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: Self.swipeMinDistance, coordinateSpace: .local)
            .updating($dragDelta) { value, state, _ in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * Self.horizontalDominance else { return }
                state = dx
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * Self.horizontalDominance else { return }
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
