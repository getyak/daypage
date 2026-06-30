import SwiftUI
import DayPageServices

// MARK: - DSSectionLabel

/// Mono-caps section label used throughout the app.
/// Renders at 11pt / Space Grotesk 700 / uppercase / tracking 1.6 / fgMuted.
/// Exposed as an h2-level heading in the accessibility tree (analogous to
/// the Web `<h2 role="heading" aria-level="2">` spec).
struct DSSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DSFonts.spaceGrotesk(size: 11, weight: .bold))
            .tracking(1.6)
            .foregroundColor(DSTokens.Colors.fgMuted)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(.h2)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 16) {
        DSSectionLabel(text: "Today")
        DSSectionLabel(text: "Recent")
        DSSectionLabel(text: "Navigate")
        DSSectionLabel(text: "Location")
    }
    .padding()
    .background(Color(red: 0.980, green: 0.973, blue: 0.965))
}
#endif
