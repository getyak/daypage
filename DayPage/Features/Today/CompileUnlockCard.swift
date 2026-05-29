import SwiftUI

// MARK: - CompileUnlockCard
//
// Museum-aesthetic timeline placeholder card (Claude Design bundle — app.jsx
// "再记一条解锁今日成稿"). A dashed accent-bordered card that sits inline in the
// Today timeline, inviting one more memo before AI weaves the day into a page.
//
//   ┌╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴┐
//   ┆ (✦)  再记一条解锁今日成稿        ┆
//   ┆      AI 将把今天的碎片连缀成日页   ┆
//   └╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴╴┘

struct CompileUnlockCard: View {
    var body: some View {
        HStack(spacing: 14) {
            // Accent-soft sparkle tile.
            ZStack {
                Circle()
                    .fill(DSColor.accentSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DSColor.accentAmber)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("再记一条解锁今日成稿")
                    .font(DSFonts.jetBrainsMono(size: 10))
                    .tracking(1.2)
                    .foregroundColor(DSColor.accentAmber)
                Text("AI 将把今天的碎片连缀成一篇日页。")
                    .font(.custom("Inter-Regular", size: 13))
                    .foregroundColor(DSColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("再记一条解锁今日成稿")
    }
}
