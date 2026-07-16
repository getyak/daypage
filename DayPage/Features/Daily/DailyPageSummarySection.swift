import SwiftUI
import DayPageModels
import DayPageServices

// MARK: - DailyPageSummarySection

/// Extracted summary block: v4 hero card narrative + threads + mentions.
/// US-024: extracted from DailyPageView to reduce its line count.
struct DailyPageSummarySection: View {

    let model: DailyPageModel
    var onMentionTap: ((String) -> Void)? = nil
    /// Issue #4: chip navigation is driven by the host NavigationStack via
    /// NavigationLink(value: UUID), so no closure needed here. Kept the
    /// symbol as documentation for readers scanning for evidence-related
    /// wiring.

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Narrative sections with hairline dividers
            if !model.sections.isEmpty {
                narrativeParagraph(model.sections[0].body)
                    .padding(.bottom, 4)
                evidenceRow(model.sections[0].evidenceMemoIDs)
                    .padding(.bottom, 8)
                ForEach(model.sections.dropFirst(), id: \.title) { section in
                    hairlineDivider.padding(.vertical, 22)
                    narrativeParagraph(section.body).padding(.bottom, 4)
                    evidenceRow(section.evidenceMemoIDs)
                        .padding(.bottom, 8)
                }
            } else if !model.summary.isEmpty {
                narrativeParagraph(model.summary).padding(.bottom, 8)
            }

            // Threads
            let displayThreads = model.threads.isEmpty ? stubThreads : model.threads
            hairlineDivider.padding(.vertical, 22)
            threadsView(threads: displayThreads)

            // Mentions
            let displayMentions = model.mentions.isEmpty ? stubMentions : model.mentions
            hairlineDivider.padding(.vertical, 22)
            mentionsView(mentions: displayMentions)
        }
    }

    // MARK: - Sub-views

    private func narrativeParagraph(_ body: String) -> some View {
        // Markdown M1: the compiler model occasionally emits **emphasis** in
        // narrative prose — render it instead of leaking syntax characters.
        Group {
            if FeatureFlagStore.shared.isEnabled(.markdownRendering) {
                MarkdownBodyView(text: body, lineSpacing: 8)
            } else {
                Text(CJKTextPolish.polish(body))
                    .font(DSType.serifBody16)
                    .foregroundColor(DSColor.inkPrimary)
                    .lineSpacing(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Issue #4: "引用 N 条" evidence chip row. Empty ID list renders
    /// nothing so historical (pre-Issue-4) daily.md files degrade
    /// gracefully. When cited, the chip uses NavigationLink(value:) so the
    /// host NavigationStack (which already handles memo.id destinations)
    /// pushes the detail without SummarySection needing its own navigation
    /// state.
    @ViewBuilder
    private func evidenceRow(_ memoIDs: [UUID]) -> some View {
        if let first = memoIDs.first {
            NavigationLink(value: first) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DSColor.inkMuted)
                    Text("引用 \(memoIDs.count) 条")
                        .font(DSFonts.spaceGrotesk(size: 11, weight: .medium, relativeTo: .caption))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.inkMuted)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(DSColor.surfaceSunken)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(DSColor.glassRimD, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { HapticFeedback.soft() })
            .accessibilityElement(children: .combine)
            .accessibilityLabel("引用 \(memoIDs.count) 条原始 memo")
            .accessibilityHint("双击打开第一条引用的原始 memo")
            .accessibilityIdentifier("daily.evidence.chip")
        }
    }

    private var hairlineDivider: some View {
        Rectangle()
            .fill(DSColor.glassRimD)
            .frame(maxWidth: .infinity)
            .frame(height: 0.5)
    }

    private func threadsView(threads: [DailyPageModel.ThreadEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THREADS")
                .font(DSFonts.spaceGrotesk(size: 11, weight: .semibold, relativeTo: .caption))
                .foregroundColor(DSColor.inkMuted)
                .tracking(1.6)
            ForEach(threads.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(threads[i].color)
                        .frame(width: 4, height: 24)
                    Text(threads[i].label)
                        .font(DSType.serifBody16)
                        .foregroundColor(DSColor.inkPrimary)
                    Spacer()
                }
            }
        }
    }

    private func mentionsView(mentions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MENTIONS")
                .font(DSFonts.spaceGrotesk(size: 11, weight: .semibold, relativeTo: .caption))
                .foregroundColor(DSColor.inkMuted)
                .tracking(1.6)
            FlowLayout(spacing: 8) {
                ForEach(mentions, id: \.self) { mention in
                    if let handler = onMentionTap {
                        Button(action: {
                            HapticFeedback.soft()
                            handler(mention)
                        }) {
                            mentionCapsule(mention)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开 \(mention) 的实体页")
                        .accessibilityHint("双击以打开 \(mention) 的实体页")
                    } else {
                        mentionCapsule(mention)
                    }
                }
            }
        }
    }

    private func mentionCapsule(_ mention: String) -> some View {
        Text(mention)
            .font(DSFonts.inter(size: 12, weight: .medium, relativeTo: .caption))
            .foregroundColor(DSColor.accentOnBg)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(DSColor.amberSoft)
            .overlay(Capsule().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
            .clipShape(Capsule())
    }

    // MARK: - Stubs

    private var stubThreads: [DailyPageModel.ThreadEntry] {
        [
            DailyPageModel.ThreadEntry(label: "Daily reflection", color: DSColor.amberAccent),
            DailyPageModel.ThreadEntry(label: "Work notes", color: DSColor.amberDeep),
        ]
    }

    private var stubMentions: [String] { ["@today", "@log"] }
}
