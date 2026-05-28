import SwiftUI

// MARK: - DSGlassPill

/// Glassmorphism pill button used in top bars (back/share/search/settings).
/// Visual spec: h=40 (sm=36), min-w=40, r=999, glass bg, backdrop blur equivalent.
struct DSGlassPill: View {
    enum Size { case sm, md }

    var size: Size = .md
    var dark: Bool = false
    var isDisabled: Bool = false
    var accessibilityLabel: String
    var action: () -> Void
    var label: AnyView

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false

    private var height: CGFloat { size == .sm ? 36 : 40 }

    private var bgMaterial: Material { .regularMaterial }

    private var overlayColor: Color {
        dark
            ? Color(red: 0.118, green: 0.110, blue: 0.094).opacity(0.62)
            : Color.white.opacity(0.78)
    }

    var body: some View {
        Button(action: {
            guard !isDisabled else { return }
            action()
        }) {
            label
                .frame(minWidth: height, minHeight: height)
                .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .background(
            ZStack {
                // Backdrop blur via Material
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(bgMaterial)
                // Tint overlay for light/dark modes
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(overlayColor)
                // Inset highlight (top edge)
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(dark ? 0.12 : 0.6),
                        lineWidth: 0.5
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
        .shadow(color: Color.black.opacity(dark ? 0.18 : 0.05), radius: 1, x: 0, y: 1)
        // Touch target extension for sm size (44pt minimum)
        .contentShape(.rect(cornerRadius: 999))
        .scaleEffect(isPressed && !isDisabled ? 0.96 : 1.0)
        .opacity(isPressed && !isDisabled ? 0.85 : (isDisabled ? 0.4 : 1.0))
        .animation(
            reduceMotion
                ? .linear(duration: 0.01)
                : .easeOut(duration: DSTokens.Motion.fast),
            value: isPressed
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isDisabled else { return }
                    isPressed = true
                }
                .onEnded { _ in
                    isPressed = false
                }
        )
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Convenience initialisers

extension DSGlassPill {
    /// Label from a SwiftUI view.
    init<Label: View>(
        size: Size = .md,
        dark: Bool = false,
        isDisabled: Bool = false,
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.size = size
        self.dark = dark
        self.isDisabled = isDisabled
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.label = AnyView(label())
    }

    /// Icon-only pill (SF Symbol).
    init(
        systemImage: String,
        size: Size = .md,
        dark: Bool = false,
        isDisabled: Bool = false,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.init(
            size: size,
            dark: dark,
            isDisabled: isDisabled,
            accessibilityLabel: accessibilityLabel,
            action: action
        ) {
            Image(systemName: systemImage)
                .font(.system(size: size == .sm ? 15 : 17, weight: .medium))
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VStack(spacing: 16) {
        DSGlassPill(systemImage: "arrow.left", accessibilityLabel: "Back") {}
        DSGlassPill(systemImage: "square.and.arrow.up", size: .sm, accessibilityLabel: "Share") {}
        DSGlassPill(size: .md, accessibilityLabel: "Search") {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search")
                    .font(.system(size: 15, weight: .medium))
            }
        }
        DSGlassPill(systemImage: "gearshape", dark: true, accessibilityLabel: "Settings") {}
        DSGlassPill(systemImage: "heart", isDisabled: true, accessibilityLabel: "Disabled") {}
    }
    .padding()
    .background(
        LinearGradient(
            colors: [Color(red: 0.8, green: 0.7, blue: 0.6), Color(red: 0.6, green: 0.5, blue: 0.4)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    )
}
#endif
