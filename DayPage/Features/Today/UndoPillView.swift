import SwiftUI

// MARK: - UndoPillView (US-009)

/// Pill shown for 5 seconds after a memo is submitted or deleted.
/// Tapping it restores the submitted text / memo to its previous state.
///
/// Escalating urgency cues over the final ~1.5s:
///  - Ring stroke transitions from amber → error red and thickens (1.5 → 2 pt)
///  - A single soft haptic fires at the 4s mark (1s remaining)
struct UndoPillView: View {
    var label: String = NSLocalizedString("undo_pill.label.send", comment: "Undo send pill label")
    let onUndo: () -> Void

    @State private var countdownProgress: CGFloat = 1.0
    @State private var isUrgent: Bool = false
    @State private var secondsRemaining: Int = 5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Work item for the haptic — cancelled on disappear so stale
    // firings don't happen after the pill is removed from the hierarchy.
    private let hapticWorkItem = HapticWorkItemHolder()


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
                Text("Undo · \(secondsRemaining)s")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Undo send, \(secondsRemaining) seconds remaining")
        .accessibilityHint("Restores the note you just submitted back to the input field")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("undo-send-pill")
        .onAppear {
            if reduceMotion {
                countdownProgress = 0
            } else {
                withAnimation(.linear(duration: 5)) {
                    countdownProgress = 0
                }
            }
            // Flip to urgent state at 3.5s (1.5s before dismissal)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                isUrgent = true
            }
            // Fire a single soft haptic at 4s (1s remaining)
            let workItem = DispatchWorkItem {
                HapticFeedback.light()
            }
            hapticWorkItem.item = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
        }
        .onDisappear {
            hapticWorkItem.item?.cancel()
            hapticWorkItem.item = nil
        }
        .task {
            for tick in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                secondsRemaining = tick
            }
        }
    }

    private var ringColor: Color {
        guard !reduceMotion else { return DSColor.accentAmber }
        return isUrgent ? DSColor.error : DSColor.accentAmber
    }
}

// MARK: - HapticWorkItemHolder

/// Reference-type box so the work item can be shared between onAppear and
/// onDisappear closures without capturing a mutating struct.
private final class HapticWorkItemHolder {
    var item: DispatchWorkItem?
}
