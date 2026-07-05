import SwiftUI

// MARK: - CompileUnlockCard
//
// Museum-aesthetic timeline placeholder card that shows the precise number of
// memos still needed before AI compilation unlocks. Three mini progress dots
// mirror the CompileProgressDock visual language.
//
//   ┌╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴┐
//   ┆ (✦)  再记 N 条解锁今日成稿      ┆
//   ┆      AI 将把今天的碎片连缀成日页  ┆
//   ┆      ● ● ○                ┆
//   └╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴┘

private struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((!reduceMotion && configuration.isPressed) ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CompileUnlockCard: View {
    let memoCount: Int
    var onTap: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false
    @State private var lastFilled: Int = 0
    @State private var poppedIndex: Int? = nil
    /// Anticipatory pulse on the next-empty dot when the user is one memo away.
    @State private var nextDotPulse = false

    private var remaining: Int { max(1, 3 - memoCount) }
    /// Index of the next dot to fill (the leftmost empty slot), or nil if full.
    private var nextEmptyIndex: Int? { memoCount < 3 ? memoCount : nil }
    /// True when a single memo separates the user from unlocking.
    private var isOneAway: Bool { remaining == 1 }

    /// Scale for a progress dot: the just-filled dot pops, the breathing
    /// next-empty dot gently swells, everything else stays at rest.
    private func dotScale(index: Int, isNext: Bool) -> CGFloat {
        if poppedIndex == index { return 1.6 }
        if isNext && isOneAway && nextDotPulse { return 1.25 }
        return 1.0
    }

    private var cardContent: some View {
        HStack(spacing: 14) {
            // Accent-soft sparkle tile with a subtle breathe shimmer.
            ZStack {
                Circle()
                    .fill(DSColor.accentSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DSColor.accentAmber)
                    .scaleEffect(shimmer ? 1.12 : 1.0)
                    .opacity(shimmer ? 1.0 : 0.7)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(isOneAway ? "再记 1 条，今日成稿就解锁" : "再记 \(remaining) 条解锁今日成稿")
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .tracking(1.2)
                    .foregroundColor(DSColor.accentOnBg)
                Text("AI 将把今天的碎片连缀成一篇日页。")
                    .font(.custom("Inter-Regular", size: 13))
                    .foregroundColor(DSColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                // Progress dots mirroring CompileProgressDock. The next-empty
                // dot breathes when the user is one memo away, drawing the eye
                // to the slot about to complete.
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        let isFilled = index < memoCount
                        let isNext = index == nextEmptyIndex
                        Circle()
                            .fill(isFilled ? DSColor.accentOnBg : DSColor.glassStd)
                            .frame(width: 5, height: 5)
                            .scaleEffect(dotScale(index: index, isNext: isNext))
                            .overlay(
                                Circle()
                                    .stroke(DSColor.accentOnBg, lineWidth: 1)
                                    .scaleEffect(isNext && isOneAway && nextDotPulse ? 2.4 : 1.0)
                                    .opacity(isNext && isOneAway && nextDotPulse ? 0 : (isNext && isOneAway ? 0.5 : 0))
                            )
                            .animation(Motion.respectReduceMotion(.spring(response: 0.3, dampingFraction: 0.55)), value: poppedIndex)
                            .animation(Motion.respectReduceMotion(Motion.spring), value: memoCount)
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    DSColor.accentBorder,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        )
        .contentShape(Rectangle())
    }

    var body: some View {
        Group {
            if let onTap {
                Button {
                    Haptics.soft()
                    onTap()
                } label: {
                    cardContent
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("再记 \(remaining) 条解锁今日成稿，已记 \(memoCount) 条")
                .accessibilityHint("轻点聚焦输入框记录新内容")
                .accessibilityAddTraits(.isButton)
            } else {
                cardContent
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("再记 \(remaining) 条解锁今日成稿，已记 \(memoCount) 条")
            }
        }
        .onChange(of: memoCount) { newCount in
            guard newCount > lastFilled else {
                lastFilled = newCount
                return
            }
            // Haptic and VoiceOver announcement fire on every increment,
            // regardless of Reduce Motion.
            Haptics.soft()
            let stillNeeded = max(0, 3 - newCount)
            if stillNeeded > 0 {
                let msg = NSLocalizedString(
                    "compile.unlock.progress",
                    value: "还需 \(stillNeeded) 条",
                    comment: "VoiceOver progress after adding a memo while unlock card is visible"
                )
                UIAccessibility.post(notification: .announcement, argument: msg)
            }
            // Dot-pop scale animation is suppressed under Reduce Motion.
            if !reduceMotion {
                poppedIndex = newCount - 1
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    poppedIndex = nil
                }
            }
            lastFilled = newCount
        }
        .onAppear {
            lastFilled = memoCount
            guard !reduceMotion else { return }
            withAnimation(
                .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
            ) {
                shimmer = true
            }
            startNextDotPulseIfNeeded()
        }
        .onChange(of: isOneAway) { _ in
            startNextDotPulseIfNeeded()
        }
    }

    /// Drive the expanding-ring + swell pulse on the next-empty dot, but only
    /// while exactly one memo remains. Toggling `nextDotPulse` inside a
    /// repeating animation produces the recurring ripple.
    private func startNextDotPulseIfNeeded() {
        guard isOneAway, !reduceMotion else {
            nextDotPulse = false
            return
        }
        nextDotPulse = false
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            nextDotPulse = true
        }
    }
}
