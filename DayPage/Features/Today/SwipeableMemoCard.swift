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
            MemoCardView(memo: memo, onDelete: onDelete)
                .offset(x: currentOffset)
                .highPriorityGesture(swipeGesture)
                .onTapGesture { if revealedSide != nil { snapClose() } }
        }
        .clipped()
    }

    // MARK: - Panels

    private var pinPanel: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            snapClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onPin?() }
        }) {
            VStack(spacing: 4) {
                Image(systemName: "pin.fill").font(.system(size: 16, weight: .semibold))
                Text("置顶").font(.custom("Inter-Medium", size: 11))
            }
            .foregroundColor(.white)
            .frame(width: panelW)
            .frame(maxHeight: .infinity)
            .background(DSColor.amberArchival)
        }
        // Opacity is driven by scoped withAnimation in snapOpen/snapClose.
        // Removed deprecated implicit .animation(_:value:) to prevent
        // animation pollution across the entire view subtree.
        .opacity(revealedSide == .leading ? 1 : 0)
    }

    private var deletePanel: some View {
        Button(action: {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
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
        // Tightened spring: response 0.22 (was 0.28), dampingFraction 0.82 (was 0.72).
        // Matches Apple HIG range and reduces visible bounce during snap.
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            revealedSide = side
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func snapClose() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            revealedSide = nil
        }
    }
}
