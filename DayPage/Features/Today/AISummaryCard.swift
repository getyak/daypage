import SwiftUI
import DayPageServices

// MARK: - AISummaryCard
//
// Museum-aesthetic "AI · 今日一句" card for the Today screen.
//
// Design intent (Claude Design bundle — composer.jsx AISummary, restrained variant):
//   • plain white surface + 0.5pt hairline border, radius 14
//   • slim 2px accent rail down the left edge
//   • header: tiny sparkle + mono "AI · 今日一句" + static "TODAY" mono label
//   • body: 19pt serif italic, revealed with a typewriter animation + blinking caret
//
// Data: bound to `TodayViewModel.dailyPageSummary` (the compiled daily summary).
// The caller is expected to only render this when a summary exists.

struct AISummaryCard: View {
    /// The compiled one-line summary to reveal.
    let summary: String
    /// When set, the card becomes tappable and opens the Daily Page.
    var onTap: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    private var shouldAnimate: Bool { !reduceMotion && !voiceOverEnabled }
    @State private var isPressed: Bool = false
    /// True once the typewriter reveal has finished (or Reduce Motion is on).
    @State private var revealComplete: Bool = false
    /// Closure provided by TypewriterText to instantly complete the reveal.
    @State private var completeReveal: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .leading) {
            // Slim accent rail (left edge).
            RoundedRectangle(cornerRadius: DSRadius.pill, style: .continuous)
                .fill(DSColor.accentOnBg)
                .opacity(0.85)
                .frame(width: 2)
                .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 8) {
                header
                TypewriterText(
                    fullText: summary,
                    animated: shouldAnimate,
                    hapticTexture: shouldAnimate,
                    isComplete: $revealComplete,
                    onCompleteHandler: $completeReveal
                )
                .font(DSType.serifQuote) // 18pt serif italic ≈ design 19pt
                .foregroundColor(DSColor.inkPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.init(top: 18, leading: 22, bottom: 20, trailing: 20))
        }
        .background(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .fill(DSColor.surfaceWhite)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)
        .scaleEffect((!reduceMotion && isPressed) ? 0.985 : 1.0)
        .animation(Motion.spring, value: isPressed)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let onTap else { return }
            // First tap while typewriter is still animating: snap the text into
            // view with a soft haptic instead of navigating.
            if shouldAnimate && !revealComplete {
                completeReveal?()
                Haptics.soft()
                return
            }
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
                .foregroundColor(DSColor.accentOnBg)
            Text("AI · 今日一句")
                .font(DSType.mono9)
                .textCase(.uppercase)
                .tracking(1.6)
                .foregroundColor(DSColor.accentOnBg)
            Spacer(minLength: 8)
            Text("TODAY")
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

// MARK: - TappableCardAccessibility

private struct TappableCardAccessibility: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("打开今日 Daily Page")
                .accessibilityAction(named: "打开 Daily Page") { action() }
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
    /// When true, a soft haptic tick fires every 4th character during the reveal.
    var hapticTexture: Bool = true
    /// Set to true by TypewriterText when the reveal finishes (or when not animated).
    var isComplete: Binding<Bool> = .constant(false)
    /// Populated by TypewriterText on appear with a closure that instantly completes
    /// the reveal; the parent can store and call it on a first-tap skip.
    var onCompleteHandler: Binding<(() -> Void)?> = .constant(nil)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownCount: Int = 0
    @State private var caretVisible: Bool = true
    @State private var didStart = false
    /// Generation counter that increments each time fullText changes or complete() is called.
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
                    .fill(DSColor.accentOnBg)
                    .frame(width: 2, height: 16)
                    .opacity(caretVisible ? 1 : 0)
            }
        }
        .onAppear {
            // Expose the complete() closure to the parent before starting the reveal.
            onCompleteHandler.wrappedValue = { complete() }
            startIfNeeded()
        }
        .onChange(of: fullText) { _ in
            // New summary → restart the reveal.
            shownCount = 0
            didStart = false
            isComplete.wrappedValue = false
            generation += 1
            startIfNeeded()
        }
    }

    /// Instantly snaps the reveal to the end and cancels any pending asyncAfter chain.
    private func complete() {
        generation += 1          // invalidates all in-flight scheduleNextChar closures
        shownCount = fullText.count
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { caretVisible = false }
        isComplete.wrappedValue = true
    }

    private func startIfNeeded() {
        guard animated, !didStart, !fullText.isEmpty else {
            if !animated {
                shownCount = fullText.count
                isComplete.wrappedValue = true
            }
            return
        }
        didStart = true
        caretVisible = true
        // 'Ready' pre-blink: the caret pulses during the 380ms lead-in before
        // the first character lands, then keeps blinking only while typing.
        // Design app.jsx:439-442 shows the caret strictly while the reveal is
        // incomplete; we stop the repeating blink in scheduleNextChar() once
        // the last char is shown so it doesn't animate a hidden view forever.
        //
        // Vestibular-sensitive: skip the repeating blink entirely under
        // Reduce Motion; leave the caret in its solid visible state.
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                caretVisible = false
            }
        }
        // Kick off the reveal after a short beat (mirrors the design's 380ms lead-in).
        scheduleNextChar(after: 0.38)
    }

    private func scheduleNextChar(after delay: Double) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [gen] in
            guard gen == generation, shownCount < fullText.count else { return }
            shownCount += 1
            // Soft haptic texture: every 4th char (skip final — completion has its own celebration).
            if hapticTexture && animated && shownCount % 4 == 0 && shownCount < fullText.count {
                Haptics.soft()
            }
            // Reveal complete → stop the repeating blink and settle the caret
            // (the caret view itself disappears via `isTyping`, but halting the
            // animation prevents a lingering repeatForever on a hidden layer).
            if shownCount >= fullText.count {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { caretVisible = false }
                isComplete.wrappedValue = true
                return
            }
            // 36–66ms jitter per char, matching the design's organic cadence.
            let jitter = Double.random(in: 0.036...0.066)
            scheduleNextChar(after: jitter)
        }
    }
}
