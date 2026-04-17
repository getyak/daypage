import SwiftUI

// MARK: - Today Empty State

struct TodayEmptyStateView: View {
    let onChipTap: (String) -> Void

    private let suggestions = [
        "今天天气如何",
        "现在在哪",
        "在想什么"
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)

            // Feather/pen illustration using SF Symbols composition
            ZStack {
                Circle()
                    .fill(DSColor.accentSoft)
                    .frame(width: 80, height: 80)
                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(DSColor.accentAmber)
            }

            // Headline
            Text("记下今天的第一个观察")
                .h2()
                .foregroundColor(DSColor.onBackgroundPrimary)
                .multilineTextAlignment(.center)

            // Suggestion chips
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { text in
                    SuggestionChip(text: text) {
                        onChipTap(text)
                    }
                }
            }

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

// MARK: - Suggestion Chip

private struct SuggestionChip: View {
    let text: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .captionText()
                .foregroundColor(DSColor.accentAmber)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DSColor.accentSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(DSColor.accentBorder, lineWidth: 1)
                )
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Archive Empty State

struct ArchiveEmptyStateView: View {
    let onGoToToday: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 32)

            ZStack {
                Circle()
                    .fill(DSColor.surfaceSunken)
                    .frame(width: 80, height: 80)
                Image(systemName: "calendar")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(DSColor.onBackgroundMuted)
            }

            Text("还没有 Daily Page")
                .h2()
                .foregroundColor(DSColor.onBackgroundPrimary)

            Button(action: onGoToToday) {
                Text("去记几条试试")
                    .captionText()
                    .foregroundColor(DSColor.accentAmber)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Graph Empty State

struct GraphEmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 32)

            ZStack {
                Circle()
                    .fill(DSColor.surfaceSunken)
                    .frame(width: 80, height: 80)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(DSColor.onBackgroundMuted)
            }

            Text("记录更多，你的知识网络会自动生成")
                .captionText()
                .foregroundColor(DSColor.onBackgroundMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity)
    }
}
