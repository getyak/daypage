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

            // Threads — hide the whole block when empty. Filling it with
            // placeholder threads shipped stub data as real content: users saw
            // "Daily reflection" / "Work notes" for days that had neither.
            if !model.threads.isEmpty {
                hairlineDivider.padding(.vertical, 22)
                threadsView(threads: model.threads)
            }

            // Mentions — likewise. The old stub emitted @today / @log, which
            // rendered as tappable entity chips leading to pages that don't
            // exist. An empty mentions list simply shows nothing.
            if !model.mentions.isEmpty {
                hairlineDivider.padding(.vertical, 22)
                mentionsView(mentions: model.mentions)
            }
        }
    }

    // MARK: - Sub-views

    private func narrativeParagraph(_ body: String) -> some View {
        // The compiler model occasionally emits **emphasis** / `#` in narrative
        // prose. MarkdownBodyView is the single ink engine: it folds those
        // markers whether or not markdown is present (plain text takes its
        // `isPlain` fast path to the same serif look). The old flag-gated
        // `else Text(polish(body))` branch skipped parsing entirely, so with
        // the experiment off users saw raw `**` asterisks — the one path that
        // leaked syntax. Rendering through MarkdownBodyView unconditionally
        // removes that leak.
        MarkdownBodyView(text: body, lineSpacing: 8)
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
                    Text(String(format: NSLocalizedString(memoIDs.count == 1 ? "daily.evidence.count.one" : "daily.evidence.count.other", comment: "Daily page evidence chip — citation count"), memoIDs.count))
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
            .accessibilityLabel(String(format: NSLocalizedString("daily.evidence.a11y", comment: "Daily page evidence chip — accessibility label"), memoIDs.count))
            .accessibilityHint(NSLocalizedString("daily.evidence.a11y.hint", comment: "Daily page evidence chip — accessibility hint"))
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
            Text(NSLocalizedString("daily.section.threads", comment: "Daily page section: threads"))
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
            Text(NSLocalizedString("daily.section.mentions", comment: "Daily page section: mentions"))
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
                        .accessibilityLabel(String(format: NSLocalizedString("daily.mention.a11y", comment: "Daily page mention — accessibility label"), mention))
                        .accessibilityHint(String(format: NSLocalizedString("daily.mention.a11y.hint", comment: "Daily page mention — accessibility hint"), mention))
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
}
