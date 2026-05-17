import SwiftUI

// MARK: - UndoPillView (US-009)

/// Pill shown for 5 seconds after a memo is submitted.
/// Tapping it restores the submitted text to the draft.
struct UndoPillView: View {
    let onUndo: () -> Void

    var body: some View {
        Button(action: onUndo) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
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
    }
}
