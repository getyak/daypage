import SwiftUI

// MARK: - DSDot

/// Decorative 3×3 pt circular dot. Hidden from the accessibility tree.
struct DSDot: View {
    var opacity: Double = 0.45

    var body: some View {
        Circle()
            .frame(width: 3, height: 3)
            .opacity(opacity)
            .accessibilityHidden(true)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    HStack(spacing: 8) {
        DSDot()
        DSDot(opacity: 1.0)
        DSDot(opacity: 0.2)
    }
    .foregroundColor(Color(red: 0.42, green: 0.40, blue: 0.38))
    .padding()
    .background(Color(red: 0.980, green: 0.973, blue: 0.965))
}
#endif
