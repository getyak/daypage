import SwiftUI

// MARK: - UndoPillView (US-009)

/// Pill shown for 5 seconds after a memo is submitted.
/// Tapping it restores the submitted text to the draft.
struct UndoPillView: View {
    let onUndo: () -> Void

    @State private var countdownProgress: CGFloat = 1.0
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
                        .stroke(DSColor.accentAmber, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
                Text("Undo send")
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
        .accessibilityLabel("Undo send")
        .accessibilityHint("Restores the note you just submitted back to the input field")
        .accessibilityAddTraits(.isButton)
        .onAppear {
            if reduceMotion {
                countdownProgress = 0
            } else {
                withAnimation(.linear(duration: 5)) {
                    countdownProgress = 0
                }
            }
        }
    }
}
