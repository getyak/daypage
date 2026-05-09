import SwiftUI

// MARK: - SwipeableMemoCard

/// WeChat-style swipe-to-reveal wrapper around MemoCardView.
/// Left swipe → trailing Delete button. Right swipe → leading Pin button.
///
/// Performance fixes (issue #150 Phase 1):
///  - Removed redundant `settledOffset` @State; offset is now derived from
///    `revealedSide`, eliminating double view invalidation on every snap.
///  - Removed deprecated implicit `.animation(_:value:)` modifiers from panels;
///    opacity is animated via the scoped `withAnimation` in snapOpen/snapClose.
///  - Tightened spring to Apple HIG values (response: 0.22, dampingFraction: 0.82)
///    for snappier 1:1 tracking and reduced visible overshoot.
///  - `PressableCardModifier` in Interactions.swift now uses `LongPressGesture`
///    instead of `DragGesture(minimumDistance: 0)` to fully eliminate the
///    dual-DragGesture hit-testing collision that caused frame drops.
struct SwipeableMemoCard: View {

    let memo: Memo
    var onDelete: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil

    // Which panel is currently revealed (single source of truth for offset)
    @State private var revealedSide: Side? = nil

    // Live delta from DragGesture (@GestureState resets automatically when finger lifts)
    @GestureState private var dragDelta: CGFloat = 0

    private enum Side { case leading, trailing }

    // Panel widths and thresholds
    private let panelW: CGFloat         = 80
    private let openThreshold: CGFloat  = 44
    private let closeThreshold: CGFloat = 20

    // Derived offset — eliminates the redundant `settledOffset` @State that caused
    // double view invalidation on every snap event.
    private var currentOffset: CGFloat {
        let settled: CGFloat = {
            switch revealedSide {
            case .trailing: return -panelW
            case nil:       return 0
            case .leading:  return panelW
            }
        }()
        return max(-panelW, min(panelW, settled + dragDelta))
    }

    // MARK: - Accessibility label derived from memo body content
    private var accessibilityMemoLabel: String {
        let prefix = memo.body.prefix(50)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Memo" : "Memo: \(trimmed)"
    }

    var body: some View {
        ZStack(alignment: .center) {
            // Background action panels
            HStack(spacing: 0) {
                pinPanel
                Spacer()
                deletePanel
            }

            // Card — highPriorityGesture wins over PressableCardModifier's
            // LongPressGesture inside MemoCardView (no drag conflict).
            // NavigationLink is disabled while a swipe panel is revealed so
            // tapping a revealed card only snaps it closed, never pushes detail.
            NavigationLink(value: memo.id) {
                MemoCardView(memo: memo, onDelete: onDelete)
            }
            .buttonStyle(.plain)
            .disabled(revealedSide != nil)
            .offset(x: currentOffset)
            .drawingGroup(opaque: false, colorMode: .extendedLinear)
            .highPriorityGesture(swipeGesture)
            .simultaneousGesture(
                TapGesture().onEnded {
                    if revealedSide != nil { snapClose() }
                }
            )
        }
        .clipped()
        // MARK: VoiceOver support — expose swipe actions as named accessibility actions
        // so users who rely on VoiceOver can invoke Delete / Pin without gestures.
        .accessibilityLabel(accessibilityMemoLabel)
        .accessibilityAction(named: "Delete") {
            onDelete?()
        }
        .accessibilityAction(named: memo.pinnedAt != nil ? "Unpin" : "Pin") {
            onPin?()
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
        // Opacity is driven by scoped withAnimation in snapOpen/snapClose.
        // Removed deprecated implicit .animation(_:value:) to prevent
        // animation pollution across the entire view subtree.
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
        // Same as pinPanel — opacity driven by scoped withAnimation, no implicit modifier.
        .opacity(revealedSide == .trailing ? 1 : 0)
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .updating($dragDelta) { value, state, _ in
                let dx = value.translation.width
                let dy = value.translation.height
                // Only track horizontal-dominant drags
                guard abs(dx) > abs(dy) * 0.6 else { return }
                state = dx
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 0.6 else {
                    // Vertical drag — stay in current settled position;
                    // @GestureState resets dragDelta automatically.
                    return
                }
                let vel = value.predictedEndTranslation.width - value.translation.width
                decideSnap(dx: dx, velocity: vel)
            }
    }

    // MARK: - Snap Logic

    private func decideSnap(dx: CGFloat, velocity: CGFloat) {
        switch revealedSide {
        case nil:
            if dx < -openThreshold || velocity < -300 {
                snapOpen(.trailing)
            } else if dx > openThreshold || velocity > 300 {
                snapOpen(.leading)
            } else {
                snapClose()
            }
        case .trailing:
            (dx > closeThreshold || velocity > 200) ? snapClose() : snapOpen(.trailing)
        case .leading:
            (dx < -closeThreshold || velocity < -200) ? snapClose() : snapOpen(.leading)
        }
    }

    private func snapOpen(_ side: Side) {
        withAnimation(Motion.spring) {
            revealedSide = side
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func snapClose() {
        withAnimation(Motion.spring) {
            revealedSide = nil
        }
    }
}
