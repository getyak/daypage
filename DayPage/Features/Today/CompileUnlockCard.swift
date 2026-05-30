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

    private var remaining: Int { max(1, 3 - memoCount) }

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
                Text("再记 \(remaining) 条解锁今日成稿")
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .tracking(1.2)
                    .foregroundColor(DSColor.accentAmber)
                Text("AI 将把今天的碎片连缀成一篇日页。")
                    .font(.custom("Inter-Regular", size: 13))
                    .foregroundColor(DSColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                // Progress dots mirroring CompileProgressDock.
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index < memoCount ? DSColor.accentAmber : DSColor.glassStd)
                            .frame(width: 5, height: 5)
                            .scaleEffect(poppedIndex == index ? 1.6 : 1.0)
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
            guard newCount > lastFilled, !reduceMotion else {
                lastFilled = newCount
                return
            }
            poppedIndex = newCount - 1
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                poppedIndex = nil
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
        }
    }
}
