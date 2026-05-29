import SwiftUI

// MARK: - AISummaryCard
//
// Museum-aesthetic "AI · 今日一句" card for the Today screen.
//
// Design intent (Claude Design bundle — composer.jsx AISummary, restrained variant):
//   • plain white surface + 0.5pt hairline border, radius 14
//   • slim 2px accent rail down the left edge
//   • header: tiny sparkle + mono "AI · 今日一句" + right-aligned timestamp
//   • body: 19pt serif italic, revealed with a typewriter animation + blinking caret
//
// Data: bound to `TodayViewModel.dailyPageSummary` (the compiled daily summary).
// The caller is expected to only render this when a summary exists.

struct AISummaryCard: View {
    /// The compiled one-line summary to reveal.
    let summary: String
    /// Timestamp shown in the header (defaults to now).
    var timestamp: Date = Date()
    /// When set, the card becomes tappable and opens the Daily Page.
    var onTap: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed: Bool = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = AppSettings.currentTimeZone()
        return f
    }()

    var body: some View {
        ZStack(alignment: .leading) {
            // Slim accent rail (left edge).
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(DSColor.accentAmber)
                .opacity(0.85)
                .frame(width: 2)
                .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 8) {
                header
                TypewriterText(
                    fullText: summary,
                    animated: !reduceMotion
                )
                .font(DSType.serifQuote) // 18pt serif italic ≈ design 19pt
                .foregroundColor(DSColor.inkPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.init(top: 18, leading: 22, bottom: 20, trailing: 20))
        }
        .background(
            RoundedRectangle(cornerRadius: DSSpacing.radiusCard, style: .continuous)
                .fill(DSColor.surfaceWhite)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSSpacing.radiusCard, style: .continuous)
                .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)
        .scaleEffect((!reduceMotion && isPressed) ? 0.985 : 1.0)
        .animation(Motion.spring, value: isPressed)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let onTap else { return }
            Haptics.tapConfirm()
            onTap()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if onTap != nil { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AI 今日一句")
        .accessibilityValue(summary)
        .modifier(TappableCardAccessibility(enabled: onTap != nil, action: { onTap?() }))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DSColor.accentAmber)
            Text("AI · 今日一句")
                .font(DSType.mono9)
                .textCase(.uppercase)
                .tracking(1.6)
                .foregroundColor(DSColor.accentAmber)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle()
                    .fill(DSColor.accentAmber)
                    .frame(width: 5, height: 5)
                Text(Self.timeFmt.string(from: timestamp))
                    .font(DSType.mono9)
                    .tracking(1.2)
                    .foregroundColor(DSColor.inkSubtle)
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DSColor.inkFaint)
                }
            }
        }
    }
}

// MARK: - TappableCardAccessibility

private struct TappableCardAccessibility: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("打开今日 Daily Page")
                .accessibilityAction(action)
        } else {
            content
        }
    }
}

// MARK: - TypewriterText
//
// Reveals `fullText` one character at a time with a blinking accent caret while
// typing. Honors Reduce Motion by showing the full text immediately.

struct TypewriterText: View {
    let fullText: String
    var animated: Bool = true

    @State private var shownCount: Int = 0
    @State private var caretVisible: Bool = true
    @State private var didStart = false
    /// Generation counter that increments each time fullText changes.
    /// Captured by asyncAfter closures so stale chains bail out.
    @State private var generation = 0

    private var isTyping: Bool { animated && shownCount < fullText.count }

    var body: some View {
        // Build the prefix lazily so we don't recompute on every redraw.
        let shown = String(fullText.prefix(animated ? shownCount : fullText.count))
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(shown)
            if isTyping {
                Rectangle()
                    .fill(DSColor.accentAmber)
                    .frame(width: 2, height: 16)
                    .opacity(caretVisible ? 1 : 0)
            }
        }
        .onAppear { startIfNeeded() }
        .onChange(of: fullText) { _ in
            // New summary → restart the reveal.
            shownCount = 0
            didStart = false
            generation += 1
            startIfNeeded()
        }
    }

    private func startIfNeeded() {
        guard animated, !didStart, !fullText.isEmpty else {
            if !animated { shownCount = fullText.count }
            return
        }
        didStart = true
        // Blink the caret.
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            caretVisible = false
        }
        // Kick off the reveal after a short beat (mirrors the design's 380ms lead-in).
        scheduleNextChar(after: 0.38)
    }

    private func scheduleNextChar(after delay: Double) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [gen] in
            guard gen == generation, shownCount < fullText.count else { return }
            shownCount += 1
            // 36–66ms jitter per char, matching the design's organic cadence.
            let jitter = Double.random(in: 0.036...0.066)
            scheduleNextChar(after: jitter)
        }
    }
}
