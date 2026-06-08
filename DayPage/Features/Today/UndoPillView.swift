import SwiftUI

// MARK: - UndoPillView (US-009)

/// Pill shown for 5 seconds after a memo is submitted or deleted.
/// Tapping it restores the submitted text / memo to its previous state.
///
/// Escalating urgency cues over the final ~3s:
///  - Ring stroke transitions from amber → error red and thickens (1.5 → 2 pt) at 3.5s
///  - Haptic ticks at 4s, 3s, 2s, 1s — intensifying in the last two (reduceMotion skips all)
///  - VoiceOver announcement at the 3s mark
struct UndoPillView: View {
    var label: String = NSLocalizedString("undo_pill.label.send", comment: "Undo send pill label")
    let onUndo: () -> Void
    var onDismiss: (() -> Void)? = nil

    @State private var countdownProgress: CGFloat = 1.0
    @State private var isUrgent: Bool = false
    @State private var secondsRemaining: Int = 5
    @State private var appeared: Bool = false
    @GestureState private var dragOffset: CGSize = .zero
    @State private var crossedDismissThreshold: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    var body: some View {
        Button {
            Haptics.tapConfirm()
            onUndo()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .semibold))
                    Circle()
                        .trim(from: 0, to: countdownProgress)
                        .stroke(
                            ringColor,
                            style: StrokeStyle(
                                lineWidth: isUrgent ? 2 : 1.5,
                                lineCap: .round
                            )
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 22, height: 22)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: isUrgent)
                        .accessibilityHidden(true)
                }
                Text("\(label) · \(secondsRemaining)s")
                    .font(.custom("Inter-Medium", size: 13))
            }
            .foregroundColor(DSColor.inkPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(DSColor.glassStd)
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DSColor.glassRim, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.92))
        .opacity({
            let baseOpacity: Double = reduceMotion ? 1 : (appeared ? 1 : 0)
            if reduceMotion { return baseOpacity }
            let dist = dragDistance(dragOffset)
            return baseOpacity * Double(max(0, 1 - dist / 80))
        }())
        .offset(
            x: reduceMotion ? 0 : (isDominantAxisHorizontal(dragOffset) ? dragOffset.width : 0),
            y: reduceMotion ? 0 : (isDominantAxisHorizontal(dragOffset) ? 0 : max(0, dragOffset.height))
        )
        .highPriorityGesture(
            DragGesture(minimumDistance: 10)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation
                }
                .onChanged { value in
                    guard !reduceMotion else { return }
                    let dist = dragDistance(value.translation)
                    if dist > 28 && !crossedDismissThreshold {
                        crossedDismissThreshold = true
                        Haptics.soft()
                    } else if dist <= 28 && crossedDismissThreshold {
                        crossedDismissThreshold = false
                    }
                }
                .onEnded { value in
                    let dist = dragDistance(value.translation)
                    if dist > 28 {
                        onDismiss?()
                    }
                    crossedDismissThreshold = false
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(secondsRemaining) seconds remaining")
        .accessibilityHint("Activate to undo; use the Dismiss action to close without undoing")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAction(named: Text("Dismiss")) { onDismiss?() }
        .accessibilityIdentifier("undo-send-pill")
        .onAppear {
            if reduceMotion {
                appeared = true
                countdownProgress = 0
            } else {
                withAnimation(Motion.spring) {
                    appeared = true
                }
                withAnimation(.linear(duration: 5)) {
                    countdownProgress = 0
                }
            }
            // Flip to urgent state at 3.5s (1.5s before dismissal)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                isUrgent = true
            }
        }
        .task {
            for remaining in stride(from: 4, through: 1, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                secondsRemaining = remaining
                if !reduceMotion {
                    Haptics.rigid(intensity: remaining <= 2 ? 0.6 : 0.3)
                }
                if remaining == 3 {
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: NSLocalizedString("undo_pill.closing", comment: "VoiceOver announcement when undo window is about to close")
                    )
                }
            }
        }
    }

    private func dragDistance(_ translation: CGSize) -> CGFloat {
        if isDominantAxisHorizontal(translation) {
            return abs(translation.width)
        }
        return max(0, translation.height)
    }

    private func isDominantAxisHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }

    private var ringColor: Color {
        guard !reduceMotion else { return DSColor.accentAmber }
        return isUrgent ? DSColor.error : DSColor.accentAmber
    }
}

