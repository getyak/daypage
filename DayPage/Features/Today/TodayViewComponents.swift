import SwiftUI
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - Today timeline components
//
// Extracted from TodayView.swift (#16 密度收敛): these are the standalone,
// state-free presentation subviews and identifiable data wrappers used by
// TodayView. Each receives its data through `let` params / closures and holds
// no reference to TodayView's own @State — so they moved out verbatim, no
// behavioral change. Grouped here as the "what the timeline is made of" file;
// the pure ViewModifiers / PreferenceKeys live in TodayViewModifiers.swift.

// MARK: - DayNavTarget

/// Identifiable wrapper around a `yyyy-MM-dd` date string that drives a
/// `navigationDestination(item:)` push to `DayDetailView`. Shared by Today
/// (On This Day / fallback / timeline entries) and Archive (calendar / list /
/// search) so both surfaces push the historical day the same way, keyed by the
/// date. `id == dateString` also makes it the stable zoom-transition identity.
struct DayNavTarget: Identifiable, Hashable {
    let dateString: String
    var id: String { dateString }
}

// MARK: - TimelineShareText

/// Identifiable wrapper around a plain-text share payload so it can drive
/// `.sheet(item:)`. Each tap on "Share" gets a fresh UUID so consecutive
/// shares of the same day still re-trigger the sheet.
struct TimelineShareText: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - CompilationFailedBanner

/// Red banner shown when background compilation failed after all retries.
/// Delegates to the shared DSBanner so the visual language matches every
/// other banner in the app (syncBanner, LocationDraftCard header, etc.).
struct CompilationFailedBanner: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        DSBanner(
            kind: .error,
            title: message,
            primaryAction: (label: "重试", action: onRetry),
            onDismiss: onDismiss
        )
        .padding(.horizontal, DSSpacing.pageMargin)
        .padding(.bottom, DSSpacing.xs)
    }
}

// MARK: - LocationDraftCard

/// Card shown at the top of Today View listing passively-detected visits pending user action.
struct LocationDraftCard: View {
    let drafts: [VisitDraft]
    let onConfirm: (VisitDraft) -> Void
    let onIgnore: (VisitDraft) -> Void
    let onConfirmAll: () -> Void
    let onIgnoreAll: () -> Void

    var body: some View {
        locationDraftContent
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    // MARK: - Location Draft Content

    private var locationDraftContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            draftHeader
            Divider().background(DSColor.inkFaint)
            draftRows
        }
        // #771: location-draft panel → glass engine (.panel). The wet-glass
        // top highlight is kept as the bespoke outer shell; the engine supplies
        // the material + perimeter rim.
        .dpGlass(.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [DSColor.glassEdge, Color.clear], startPoint: .top, endPoint: .center), lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color(hex: "2D1E0A").opacity(0.04), radius: 1, x: 0, y: 1)
        .shadow(color: Color(hex: "2D1E0A").opacity(0.08), radius: 24, x: 0, y: 8)
    }

    // MARK: - Draft Header

    private var draftHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(DSType.label)
                .foregroundColor(DSColor.amberAccent)
            Text(NSLocalizedString("today.location_draft.header", comment: "Location draft header"))
                .font(DSType.caption)
                .foregroundColor(DSColor.inkPrimary)
            Spacer()
            Button(NSLocalizedString("today.location_draft.ignore_all", comment: "Ignore all location drafts")) { onIgnoreAll() }
                .font(DSType.caption)
                .foregroundColor(DSColor.inkMuted)
                .accessibilityLabel(NSLocalizedString("today.location_draft.ignore_all.a11y", comment: "Ignore all location drafts accessibility label"))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            Button(NSLocalizedString("today.location_draft.confirm_all", comment: "Confirm all location drafts")) { onConfirmAll() }
                .font(DSType.caption)
                .foregroundColor(DSColor.amberAccent)
                .accessibilityLabel(NSLocalizedString("today.location_draft.confirm_all.a11y", comment: "Confirm all location drafts accessibility label"))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Draft Rows

    private var draftRows: some View {
        ForEach(Array(drafts.enumerated()), id: \.element.id) { idx, draft in
            VStack(spacing: 0) {
                LocationDraftRow(
                    draft: draft,
                    onConfirm: { onConfirm(draft) },
                    onIgnore: { onIgnore(draft) }
                )
                if idx < drafts.count - 1 {
                    Divider()
                        .background(DSColor.inkFaint)
                        .padding(.leading, 16)
                }
            }
        }
    }
}

// MARK: - LocationDraftRow

private struct LocationDraftRow: View {
    let draft: VisitDraft
    let onConfirm: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(DSType.headlineCaps)
                .foregroundColor(DSColor.amberAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.placeName ?? NSLocalizedString("today.location_draft.unknown_place", comment: "Unknown place"))
                    .font(DSType.caption)
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(formatTime(draft.arrivalDate))
                        .font(DSType.mono10)
                        .foregroundColor(DSColor.inkMuted)
                        .textCase(.uppercase)
                    if let dur = durationText {
                        Text("·")
                            .font(DSType.mono10)
                            .foregroundColor(DSColor.inkMuted)
                        Text(dur)
                            .font(DSType.mono10)
                            .foregroundColor(DSColor.inkMuted)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    onIgnore()
                } label: {
                    Image(systemName: "xmark")
                        .font(DSType.label)
                        .foregroundColor(DSColor.inkMuted)
                        .frame(width: 30, height: 30)
                        // #771: ignore-location button → glass engine (.control).
                        .dpGlass(.control, in: Circle())
                        .clipShape(Circle())
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(NSLocalizedString("today.location_draft.ignore_one.a11y", comment: "Ignore one location draft"))

                Button {
                    onConfirm()
                } label: {
                    Image(systemName: "checkmark")
                        .font(DSType.label)
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(DSColor.amberAccent)
                        .clipShape(Circle())
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(NSLocalizedString("today.location_draft.confirm_one.a11y", comment: "Confirm one location draft"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func formatTime(_ date: Date) -> String {
        DateFormatters.timeHHmm.string(from: date)
    }

    private var durationText: String? {
        guard let dep = draft.departureDate else { return NSLocalizedString("today.location_draft.still_here", comment: "Visit has not ended") }
        let secs = dep.timeIntervalSince(draft.arrivalDate)
        guard secs > 0 else { return nil }
        let mins = Int(secs / 60)
        if mins < 60 { return String(format: NSLocalizedString("today.location_draft.stayed_minutes", comment: "Visit duration in minutes"), mins) }
        let h = mins / 60; let m = mins % 60
        return m == 0
            ? String(format: NSLocalizedString("today.location_draft.stayed_hours", comment: "Visit duration in hours"), h)
            : String(format: NSLocalizedString("today.location_draft.stayed_hours_minutes", comment: "Visit duration in hours and minutes"), h, m)
    }
}

// MARK: - CompilationProgressBar

/// Thin progress strip shown at the top of TodayView while AI compilation runs.
struct CompilationProgressBar: View {
    let stage: CompilationStage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: Double {
        switch stage {
        case .extracting: return 0.25
        case .compiling:  return 0.60
        case .formatting: return 0.85
        case .done:       return 1.00
        }
    }

    private var label: String {
        switch stage {
        case .extracting: return "读取记录…"
        case .compiling:  return "AI 编译中…"
        case .formatting: return "整理格式…"
        case .done:       return "完成"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DSColor.glassStd)
                        .frame(height: 3)
                    // Progress fill is a BACKGROUND state, not a call to action —
                    // per the "one amber lead per screen" law it must not compete
                    // with the mic orb for the accent budget. Ink at 55% reads as a
                    // determinate meter (quiet, mono-family with the % label below)
                    // rather than a branded highlight. Was `accentAmber`.
                    Capsule()
                        .fill(DSColor.inkPrimary.opacity(0.55))
                        .frame(width: geo.size.width * progress, height: 3)
                        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: progress)
                }
            }
            .frame(height: 3)

            Text(label)
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkMuted)
                .textCase(.uppercase)
                .tracking(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}

// MARK: - TimelineRow

/// V4: Direct card stack — no left timeline column. Cards float edge-to-edge
/// over the ambient background, letting the glass surface provide depth.
struct TimelineRow: View {
    let memo: Memo
    let isLast: Bool
    var onDelete: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil
    var onRetranscribe: ((Memo, Memo.Attachment) -> Void)? = nil
    /// Issue #302: long-press → "分享为卡片"
    var onShare: (() -> Void)? = nil
    /// Issue #302: long-press → "分享为引用"
    var onShareAsQuote: (() -> Void)? = nil
    /// Issue #309 W2: long-press → "多选". Enters selection mode and
    /// seeds the selection with the long-pressed memo. nil hides the menu
    /// item (e.g. when already in selection mode).
    var onEnterSelectionMode: (() -> Void)? = nil
    /// Issue #309 W2: selection mode props. When isSelectionMode is true,
    /// the card renders with a selection indicator overlay and a tap
    /// toggles membership instead of navigating to the detail view.
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)? = nil
    /// Tap on the card body → open detail. Driven programmatically by the
    /// parent (the swipe card no longer uses a NavigationLink).
    var onOpen: (() -> Void)? = nil

    /// Drives the right-swipe MORE confirmation dialog (pin / delete / …).
    /// Since the swipe drawer's leading side became insight/related, this
    /// dialog is now opened from the long-press menu's 「更多操作」 item —
    /// pin/more stay reachable in the long-press menu and this dialog.
    @State private var showMoreActions = false

    /// Anchored memo-chat sheet (flomo-native refinement): non-nil while the
    /// insight chooser / related-question sheet should be presented. Hosted
    /// on the row so every TimelineRow surface (Today / Archive / Daily) gets
    /// the same anchored chat without per-surface wiring.
    @State private var chatRequest: MemoChatSheetRequest?
    @State private var chatOpeningTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 2026-07-04: the long-press menu is applied conditionally — in
        // selection mode a long press must do NOTHING (no menu, no preview
        // lift), so we branch on the flag instead of emptying the items.
        // This is also where the old double-contextMenu bug died: the card
        // (SwipeableMemoCard) used to carry its own share/pin/delete menu
        // that shadowed this one; both sets now merge here, over a real
        // card preview.
        if isSelectionMode {
            cardStack
        } else {
            cardStack
                // Long-press lift snapshot must share the card's 14pt
                // continuous silhouette — without this the system clips the
                // lift highlight to a square rect, flashing hard corners
                // around a rounded card for the first frames of the pick-up.
                .contentShape(
                    .contextMenuPreview,
                    RoundedRectangle(
                        cornerRadius: SwipePhysics.cardCornerRadius,
                        style: .continuous
                    )
                )
                .contextMenu {
                    mergedMenuItems
                } preview: {
                    // Full-bleed card snapshot lifted out of the timeline —
                    // reuses MemoCardView so the preview is the card, not a
                    // cropped screenshot of the row.
                    MemoCardView(memo: memo)
                        .frame(width: SwipePhysics.contextPreviewWidth)
                }
        }
    }

    /// The card + selection chrome + MORE dialog, shared by both branches
    /// of `body`.
    private var cardStack: some View {
        ZStack(alignment: .topTrailing) {
            // In selection mode the inner NavigationLink must be disabled
            // (otherwise a tap routes to detail). We pass isSelectionMode
            // down so SwipeableMemoCard can mute its swipe gesture too —
            // both behaviors live on a single flag at the card root.
            SwipeableMemoCard(
                memo: memo,
                onDelete: onDelete,
                onPin: onPin,
                onShare: onShare,            // left-swipe SHARE → share-as-card
                // Pin / more no longer ride the swipe drawer (right-swipe is
                // insight/related); the dialog stays open from the long-press
                // menu's 「更多操作」 item so the action set stays complete.
                onMore: { showMoreActions = true },
                // Right-swipe INSIGHT → anchored chat with the insight-lens
                // chooser expanded. Presentation only — no AI call, no
                // persistence happens until the user acts inside the sheet.
                onInsight: {
                    openChat(related: false)
                },
                // Right-swipe RELATED → same anchored sheet with a suggested
                // question prefilled. Never auto-submitted.
                onRelated: {
                    openChat(related: true)
                },
                // Card-body tap: in selection mode toggle membership, else open
                // detail. Both flow through the card's UIKit tap recognizer so
                // they never fight the swipe gesture's self-hit-testing host.
                onOpen: {
                    if isSelectionMode {
                        Haptics.soft()
                        onToggleSelection?()
                    } else {
                        onOpen?()
                    }
                },
                onRetranscribe: onRetranscribe,
                isSelectionMode: isSelectionMode
            )
            .frame(maxWidth: .infinity)
            // Dimmer when in selection mode but not selected — pulls focus
            // toward the picked memos without hiding the others completely.
            .opacity(isSelectionMode && !isSelected ? 0.55 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelected)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelectionMode)

            // Selection circle indicator, top-trailing.
            if isSelectionMode {
                selectionIndicator
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .transition(.opacity)
            }
        }
        // Right-swipe MORE → fuller action set (pin / quote / delete) kept
        // out of the card's resting chrome per the content-first redesign.
        .confirmationDialog(
            NSLocalizedString("memo.swipe.more", comment: "more dialog title"),
            isPresented: $showMoreActions,
            titleVisibility: .hidden
        ) {
            moreActionsButtons
        }
        // The memo-anchored chat sheet (insight chooser / related question).
        // sheet(item:) so the presentation is anchored to the exact swiped
        // memo and re-triggers cleanly on every swipe.
        .sheet(item: $chatRequest) { request in
            MemoChatView(
                memo: request.memo,
                entityDisplayNames: request.entityDisplayNames,
                onClose: { chatRequest = nil },
                initialMode: request.mode
            )
            .presentationDetents([.fraction(0.85), .large])
            .presentationDragIndicator(.visible)
        }
        .onDisappear {
            chatOpeningTask?.cancel()
            chatOpeningTask = nil
        }
    }

    private func openChat(related: Bool) {
        guard !isSelectionMode else { return }
        chatOpeningTask?.cancel()
        let anchor = memo
        let slugs = memo.entityMentions
        let wikiBase = VaultInitializer.vaultURL.appendingPathComponent("wiki")
        chatOpeningTask = Task { @MainActor in
            let names = await Task.detached(priority: .userInitiated) {
                Self.derivedEntityNames(slugs: slugs, wikiBase: wikiBase)
            }.value
            guard !Task.isCancelled else { return }
            let mode: MemoChatEntryMode = related
                ? .related(question: relatedQuestion(names: names)) : .insight
            chatRequest = MemoChatSheetRequest(memo: anchor, mode: mode, entityDisplayNames: names)
            chatOpeningTask = nil
        }
    }

    /// The suggested question the RELATED action prefills into the chat
    /// input — entity-aware when names resolve, a neutral temporal question
    /// otherwise. It is prefilled only; the user sends it (or edits it).
    private func relatedQuestion(names: [String: String]) -> String {
        if let name = names.values.sorted().first {
            return String(format: NSLocalizedString(
                "memo.chat.suggest.entity",
                value: "What else have I said about “%@”?",
                comment: "Memo chat — suggested question 2; %@ is an entity name"
            ), name)
        }
        return NSLocalizedString(
            "memo.chat.suggest.related",
            value: "What else was happening around this entry?",
            comment: "Memo chat — related-suggestion question when no entity names resolve"
        )
    }

    /// Best-effort entity display names for the chat sheet: resolves wiki
    /// frontmatter `name:` for the memo's entity mentions. Falls back to an
    /// empty dictionary when nothing resolves (MemoChatView tolerates that —
    /// the memo row has no pre-resolved names of its own).
    private nonisolated static func derivedEntityNames(slugs: [String], wikiBase: URL) -> [String: String] {
        var names: [String: String] = [:]
        for slug in Set(slugs).filter({ !$0.isEmpty }).sorted() {
            let safeSlug = EntityPageService.sanitizeSlug(slug)
            for type in ["places", "people", "themes"] {
                let url = wikiBase
                    .appendingPathComponent(type)
                    .appendingPathComponent("\(safeSlug).md")
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if let name = FrontmatterParser.extractField("name", from: content),
                   !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    names[slug] = name
                    break
                }
            }
        }
        return names
    }

    /// Single merged long-press menu: pin + both share forms + multi-select,
    /// then delete isolated behind a divider. Mirrors every swipe-revealed
    /// action so the menu alone is a complete control surface.
    @ViewBuilder
    private var mergedMenuItems: some View {
        if let onPin {
            Button {
                Haptics.tapConfirm()
                onPin()
            } label: {
                let pinned = memo.pinnedAt != nil
                Label(
                    pinned
                        ? NSLocalizedString("memo.swipe.unpin", comment: "contextMenu: unpin memo")
                        : NSLocalizedString("memo.swipe.pin",   comment: "contextMenu: pin memo"),
                    systemImage: pinned ? "pin.slash" : "pin"
                )
            }
        }
        // Every item in this menu confirms under the finger — three of them
        // used to fire silently, which read as a missed tap.
        if let onShare {
            Button {
                Haptics.tapConfirm()
                onShare()
            } label: {
                Label(NSLocalizedString("memo.menu.shareCard", comment: "contextMenu: share memo as card"),
                      systemImage: "square.and.arrow.up.on.square")
            }
        }
        if let onShareAsQuote {
            Button {
                Haptics.tapConfirm()
                onShareAsQuote()
            } label: {
                Label(NSLocalizedString("memo.menu.shareQuote", comment: "contextMenu: share memo as quote"),
                      systemImage: "quote.opening")
            }
        }
        // Copy lived on a contextMenu INSIDE MemoCardView, which the swipe
        // gesture's overlay shadowed — it could never be summoned. The merged
        // menu is the single reachable long-press surface, so Copy belongs
        // here. Voice memos with an empty body copy their transcript instead.
        if !copyableText.isEmpty {
            Button {
                UIPasteboard.general.string = copyableText
                Haptics.tapConfirm()
            } label: {
                Label(NSLocalizedString("memo.menu.copyText", comment: "contextMenu: copy memo text"),
                      systemImage: "doc.on.doc")
            }
        }
        if let onEnterSelectionMode {
            Button {
                // selection() rather than tapConfirm() — this enters a mode
                // rather than committing an action.
                Haptics.selection()
                onEnterSelectionMode()
            } label: {
                Label(NSLocalizedString("memo.menu.multiselect", comment: "contextMenu: enter multi-select mode"),
                      systemImage: "checkmark.circle")
            }
        }
        // Pin / more live in the long-press surface and this dialog (the
        // swipe drawer's leading side is now insight/related), so the menu
        // needs one explicit route into the fuller action set.
        Button {
            Haptics.selection()
            showMoreActions = true
        } label: {
            Label(NSLocalizedString("memo.menu.moreActions", comment: "contextMenu: open the more-actions dialog"),
                  systemImage: "ellipsis")
        }
        if let onDelete {
            Divider()
            Button(role: .destructive) {
                Haptics.warningNotification()
                onDelete()
            } label: {
                Label(NSLocalizedString("memo.swipe.delete", comment: "contextMenu: delete memo"),
                      systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var moreActionsButtons: some View {
        if let onPin {
            Button(memo.pinnedAt != nil
                ? NSLocalizedString("memo.swipe.unpin", comment: "more dialog: unpin memo")
                : NSLocalizedString("memo.swipe.pin", comment: "more dialog: pin memo")) { onPin() }
        }
        if let onShareAsQuote {
            Button(NSLocalizedString("memo.menu.shareQuote", comment: "more dialog: share as quote")) { onShareAsQuote() }
        }
        if let onEnterSelectionMode {
            Button(NSLocalizedString("memo.menu.multiselect", comment: "more dialog: multi-select")) { onEnterSelectionMode() }
        }
        if let onDelete {
            Button(NSLocalizedString("memo.swipe.delete", comment: "more dialog: delete memo"), role: .destructive) { onDelete() }
        }
        Button(NSLocalizedString("memo.menu.cancel", comment: "more dialog: cancel"), role: .cancel) { }
    }

    /// Text the long-press Copy action puts on the pasteboard: the visible
    /// body, or — for voice memos whose body is empty — the transcript.
    private var copyableText: String {
        let body = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body }
        return memo.attachments
            .first(where: { $0.kind == "audio" })?
            .transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .fill(isSelected ? DSColor.amberDeep : Color.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(DSType.caption)
                    .foregroundColor(.white)
            } else {
                Circle()
                    .strokeBorder(DSColor.inkSubtle.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 26, height: 26)
            }
        }
        .accessibilityLabel(NSLocalizedString(isSelected ? "common.selected" : "common.not_selected", comment: "Selection state"))
    }
}
