import SwiftUI
import MapKit
import ImageIO
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - MemoDetailView

struct MemoDetailView: View {

    let memo: Memo
    let vm: any MemoDetailViewModel
    /// Back-button label — defaults to "Today" for the Today-feed entry;
    /// other hosts (DailyPageView) pass their own so the button never lies
    /// about where dismissal lands.
    var backLabel: String = NSLocalizedString(
        "memo.detail.nav.back",
        value: "Today",
        comment: "Detail view — back-to-today button label"
    )

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var nav: AppNavigationModel
    @State private var fullResImage: UIImage?
    @State private var showPhotoFullscreen: Bool = false

    // Edit body state
    @State private var isEditingBody: Bool = false
    @State private var editedBody: String = ""
    /// Content-driven editor height, measured by MarkdownEditor's coordinator.
    @State private var editorHeight: CGFloat = 180
    /// Bridges the docked format bar to the editor's coordinator.
    @StateObject private var editorController = MarkdownEditorController()

    // Delete confirmation
    @State private var showDeleteConfirm: Bool = false

    // Share sheet (mono text → UIActivityViewController)
    @State private var showShareSheet: Bool = false

    // Poster share (card/quote) — same ShareCardSheet pipeline as Today/Daily,
    // so memo detail is no longer the one surface stuck with raw-text sharing.
    @State private var sharePayload: SharePayload? = nil

    /// "2026-07-16 · 宁曼路" — date plus location when available, matching the
    /// attribution format the Daily page quote path uses.
    private var quoteAttribution: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var attrib = df.string(from: memo.created)
        if let loc = memo.location?.name, !loc.isEmpty {
            attrib += " · " + loc
        }
        return attrib
    }

    // Entity Ink — tapped entity pushes its wiki page onto the host stack
    // (W1; issue #835). No local sheet state anymore — see openEntity(slug:).

    // Drop-to-Ask — memo 锚定 AI 对话（issue #837）：拖拽入坞或 CTA 触发。
    @State private var showMemoChat: Bool = false
    /// slug → wiki display name; resolved async so CJK prose (which never
    /// contains the latin slug) can still be inked by its display name.
    @State private var entityDisplayNames: [String: String] = [:]

    private var kickerText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd  HH:mm"
        return f.string(from: memo.created).uppercased()
    }

    var body: some View {
        ZStack(alignment: .top) {
            AmbientBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // MARK: Navigation Bar Row
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 13, weight: .medium))
                                Text(backLabel)
                                    .font(DSType.bodySM)
                            }
                            .foregroundColor(DSColor.inkMuted)
                        }
                        // #150 shared press feedback — chrome buttons dip on
                        // touch instead of feeling dead. Aligns to the icon-
                        // button sample (0.97 / +0.5pt).
                        .pressScale(scale: 0.97, offsetY: 0.5,
                                    animation: .spring(response: 0.2, dampingFraction: 0.7))
                        .accessibilityLabel(NSLocalizedString(
                            "memo.detail.a11y.back",
                            value: "返回今天",
                            comment: "Detail view — back button VoiceOver label"
                        ))

                        Spacer()

                        Menu {
                            Button {
                                startBodyEdit()
                            } label: {
                                Label(NSLocalizedString(
                                    "memo.detail.action.edit",
                                    value: "Edit Body",
                                    comment: "Detail view — menu: edit body"
                                ), systemImage: "pencil")
                            }

                            Button {
                                UIPasteboard.general.string = memo.body
                                Haptics.tapConfirm()
                            } label: {
                                Label(NSLocalizedString(
                                    "memo.detail.action.copy",
                                    value: "Copy Text",
                                    comment: "Detail view — menu: copy body"
                                ), systemImage: "doc.on.doc")
                            }

                            Button {
                                Haptics.soft()
                                sharePayload = SharePayload.auto(from: memo)
                            } label: {
                                Label(NSLocalizedString(
                                    "memo.detail.action.shareCard",
                                    value: "Share as Card",
                                    comment: "Detail view — menu: share as poster card"
                                ), systemImage: "square.and.arrow.up")
                            }

                            Button {
                                Haptics.soft()
                                sharePayload = .quote(QuoteSnapshot(
                                    text: MemoMarkdown.plainText(memo.body),
                                    attribution: quoteAttribution
                                ))
                            } label: {
                                Label(NSLocalizedString(
                                    "memo.detail.action.shareQuote",
                                    value: "Share as Quote",
                                    comment: "Detail view — menu: share as quote card"
                                ), systemImage: "quote.opening")
                            }

                            Button {
                                Haptics.soft()
                                showShareSheet = true
                            } label: {
                                Label(NSLocalizedString(
                                    "memo.detail.action.share",
                                    value: "Share as Text",
                                    comment: "Detail view — menu: share plain text"
                                ), systemImage: "text.alignleft")
                            }

                            Divider()

                            Button(role: .destructive) {
                                // Destructive: use the warning notification
                                // pulse rather than the lighter confirm tick
                                // so the haptic itself signals irreversibility.
                                Haptics.warningNotification()
                                showDeleteConfirm = true
                            } label: {
                                Label(NSLocalizedString(
                                    "memo.detail.action.delete",
                                    value: "Delete Memo",
                                    comment: "Detail view — menu: delete"
                                ), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(DSColor.inkMuted)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString(
                            "memo.detail.a11y.menu",
                            value: "更多操作",
                            comment: "Detail view — ellipsis menu a11y"
                        ))
                    }
                    .padding(.top, DSSpacing.lg)
                    .padding(.bottom, DSSpacing.xl)

                    // MARK: Kicker — mono date + time
                    Text(kickerText)
                        .font(DSType.mono10)
                        .foregroundColor(DSColor.inkMuted)
                        .tracking(1.2)
                        .padding(.bottom, 14)

                    // MARK: Serif Body (view or edit)
                    let bodyTrimmed = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    let hasAudio = memo.attachments.contains(where: { $0.kind == "audio" })
                    let isBodyDuplicate = hasAudio &&
                        memo.attachments.contains(where: { att in
                            att.kind == "audio" &&
                            att.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) == bodyTrimmed &&
                            !bodyTrimmed.isEmpty
                        })

                    if isEditingBody {
                        // In-place editing cabin (Markdown M3, WYSIWYG):
                        // prose reads fully rendered — syntax characters
                        // conceal except on the caret's line (Typora line-
                        // reveal) — with the format bar docked to the
                        // cabin's bottom edge.
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(spacing: 0) {
                                MarkdownEditor(
                                    text: $editedBody,
                                    measuredHeight: $editorHeight,
                                    controller: editorController
                                )
                                .frame(height: editorHeight)

                                MarkdownFormatBar { action in
                                    editorController.perform(action)
                                }
                            }
                                .background(DSColor.glassLo)
                                .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                                        .strokeBorder(DSColor.amberRim, lineWidth: 0.5)
                                )

                            HStack(spacing: DSSpacing.md) {
                                Button {
                                    Haptics.soft()
                                    dismissKeyboard()
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        isEditingBody = false
                                    }
                                } label: {
                                    Text(NSLocalizedString(
                                        "memo.detail.edit.cancel",
                                        value: "Cancel",
                                        comment: "Detail view — cancel body edit"
                                    ))
                                    .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                                    .tracking(0.6)
                                    .textCase(.uppercase)
                                    .foregroundColor(DSColor.inkMuted)
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    Haptics.tapConfirm()
                                    dismissKeyboard()
                                    vm.update(memo: memo, body: editedBody)
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        isEditingBody = false
                                    }
                                } label: {
                                    Text(NSLocalizedString(
                                        "memo.detail.edit.save",
                                        value: "Save",
                                        comment: "Detail view — save body edit"
                                    ))
                                    .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                                    .tracking(0.6)
                                    .textCase(.uppercase)
                                    .foregroundColor(DSColor.accentOnBg)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(DSColor.amberSoft)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                                .disabled(editedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .pressScale(scale: 0.96, opacity: 0.9,
                                            animation: .spring(response: 0.2, dampingFraction: 0.7))
                                .accessibilityIdentifier("memo.detail.body.save")
                            }
                        }
                        .padding(.bottom, 14)
                    } else if !bodyTrimmed.isEmpty && !isBodyDuplicate {
                        // Markdown M1 — full block rendering with entity ink
                        // merged in one pass (MarkdownBodyView is the ink
                        // engine; flag-off falls back inside via isPlain to
                        // the same serif look, so only the markdown parse is
                        // gated here).
                        Group {
                            if FeatureFlagStore.shared.isEnabled(.markdownRendering) {
                                MarkdownBodyView(
                                    text: bodyTrimmed,
                                    // Line-spacing 8 (≈1.5× serifBody16) so
                                    // long-form journal entries breathe like a
                                    // printed page.
                                    lineSpacing: 8,
                                    blockSpacing: 12,
                                    entitySlugs: memo.entityMentions,
                                    entityDisplayNames: entityDisplayNames
                                )
                            } else {
                                Text(inkedBody(bodyTrimmed))
                                    .font(DSType.serifBody16)
                                    .foregroundColor(DSColor.inkPrimary)
                                    .lineSpacing(8)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .contentShape(Rectangle())
                        // Tap the prose to edit it — the ellipsis-menu route
                        // stays for discoverability, but the body itself is
                        // the affordance. Entity links keep priority: link
                        // taps are handled by Text before this gesture.
                        .onTapGesture {
                            startBodyEdit()
                        }
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "daypage-entity" else { return .systemAction }
                            if let slug = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                                .queryItems?.first(where: { $0.name == "s" })?.value {
                                openEntity(slug: slug)
                            }
                            return .handled
                        })
                        .accessibilityHint(NSLocalizedString(
                            "memo.detail.a11y.tap_to_edit",
                            value: "双击以编辑正文",
                            comment: "Detail view — body tap-to-edit VoiceOver hint"
                        ))
                    }

                    // MARK: AI Marginalia (issue #835)
                    // A compilation-written observation, set like a pencil
                    // note in the page margin — thin amber rule, serif
                    // italic, quieter than the body it annotates.
                    if !isEditingBody,
                       let note = memo.marginNote?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !note.isEmpty {
                        Text(note)
                            .font(DSFonts.serif(size: 13, weight: .regular, relativeTo: .footnote).italic())
                            .foregroundColor(DSColor.accentOnBg.opacity(0.8))
                            .lineSpacing(4)
                            .padding(.leading, 12)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(DSColor.amberRim)
                                    .frame(width: 2)
                            }
                            .padding(.top, 16)
                            .accessibilityLabel(NSLocalizedString(
                                "memo.detail.a11y.margin_note",
                                value: "AI 眉批",
                                comment: "Detail view — marginalia VoiceOver label"
                            ))
                    }

                    // MARK: Attachment Sections
                    let audioAtts = memo.attachments.filter { $0.kind == "audio" }
                    let photoAtts = memo.attachments.filter { $0.kind == "photo" }
                    let fileAtts  = memo.attachments.filter { $0.kind == "file" }
                    let hasLocation = memo.location?.lat != nil

                    if !audioAtts.isEmpty || !photoAtts.isEmpty || !fileAtts.isEmpty || hasLocation {
                        Divider()
                            .background(DSColor.inkFaint)
                            .padding(.vertical, DSSpacing.xl)

                        VStack(alignment: .leading, spacing: DSSpacing.xl) {

                            // Voice
                            ForEach(audioAtts, id: \.file) { att in
                                DetailVoiceSection(attachment: att)
                            }

                            // Photo
                            ForEach(photoAtts, id: \.file) { att in
                                DetailPhotoSection(
                                    attachment: att,
                                    fullResImage: $fullResImage,
                                    showFullscreen: $showPhotoFullscreen
                                )
                            }

                            // Location
                            if hasLocation {
                                DetailLocationSection(
                                    location: memo.location,
                                    memoDateString: DateFormatters.isoDate.string(from: memo.created),
                                    onOpenPlace: { slug in
                                        nav.push(
                                            EntityRef(
                                                type: "places",
                                                slug: slug,
                                                sourceDateString: DateFormatters.isoDate.string(from: memo.created)
                                            ),
                                            in: nav.selectedTab
                                        )
                                    }
                                )
                            }

                            // Files
                            if !fileAtts.isEmpty {
                                DetailFilesSection(attachments: fileAtts)
                            }
                        }
                    }

                    // MARK: Ask Past Self (Issue #11, 2026-07-03)
                    //
                    // MARK: Echoes — related memories via entity overlap
                    // (issue #835). Pure-local scan, renders nothing when the
                    // memo has no compiled entity mentions or no kin.
                    EchoesSection(memo: memo, onOpen: openEcho)

                    // Anchored just above the metadata footer. Opens the
                    // shared AskPastView (D1 memory-chat agent) with the
                    // current memo's body pre-seeded as the retrieval
                    // context. The action fires the standard
                    // `daypage://ask?q=` URL so navModel + RootView keep
                    // authoritative — no new sheet plumbing here.
                    // No divider above: the amber card is self-delimiting, and
                    // a rule here boxed the CTA between two full-width lines.
                    Button {
                        Haptics.tapConfirm()
                        // Issue #837: 直接呈现 memo 锚定对话（不再走
                        // daypage://ask URL round-trip）——memo 全文 + 实体
                        // 作为一等上下文进入 Agent 检索循环。此 CTA 与
                        // Drop-to-Ask 拖拽手势通向同一个 sheet：拖拽是
                        // 彩蛋，CTA 是明路（也是无障碍路径）。
                        showMemoChat = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(DSColor.accentOnBg)
                            Text(NSLocalizedString(
                                "memo.detail.ask_past",
                                value: "Ask your past self",
                                comment: "Detail view — ask-past-self CTA label"
                            ))
                                .font(DSType.bodySM)
                                .foregroundColor(DSColor.accentOnBg)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DSColor.accentOnBg.opacity(0.65))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, DSSpacing.md)
                        .background(DSColor.amberSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: DSRadius.md)
                                .strokeBorder(DSColor.amberRim, lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
                    }
                    // #150 press feedback — this is a card-style CTA, so a
                    // slightly deeper dip with a fade reads as "the panel presses".
                    .pressScale(scale: 0.98, opacity: 0.92,
                                animation: .spring(response: 0.25, dampingFraction: 0.72))
                    .accessibilityIdentifier("memo.detail.ask.past")
                    .padding(.top, 28)

                    // MARK: Metadata Section
                    Divider()
                        .background(DSColor.inkFaint)
                        .padding(.vertical, DSSpacing.xl)

                    DetailMetadataSection(memo: memo)

                    // Tightened from 40→24 so the metadata section anchors the
                    // page instead of floating in a dead-zone at the bottom.
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, DSSpacing.xl2)
                .padding(.bottom, 32)
            }
            // Issue #837: 小红书式拖拽——横向起手把整页凝缩成卡片，
            // 投入底部对话坞 → memo 锚定 AI 对话；坞外右移超阈值 → 返回。
            // 只包 ScrollView：AmbientBackground 留在原位当拖拽的舞台底。
            .dropToAsk(
                isEnabled: !isEditingBody,
                onAsk: { showMemoChat = true },
                onCommitBack: { dismiss() }
            )
        }
        .navigationBarHidden(true)
        .onAppear {
            // Issue #18 (2026-07-03): capture the detail-open funnel so
            // the debug board can show how many memo cards actually got
            // read vs. swiped past. Fires from the top-level body so
            // `memo` is in scope (was misplaced inside DetailFileRow's
            // onAppear last edit).
            AnalyticsService.shared.record(
                AnalyticsService.Name.detailOpened,
                props: ["memo_id": memo.id.uuidString]
            )
        }
        .task(id: memo.id) {
            let slugs = memo.entityMentions.filter { !$0.isEmpty }
            guard !slugs.isEmpty else { return }
            entityDisplayNames = await Task.detached(priority: .utility) {
                Self.resolveDisplayNames(for: slugs)
            }.value
        }
        .fullScreenCover(isPresented: $showPhotoFullscreen) {
            PhotoFullscreenView(image: fullResImage)
        }
        // W1: entity ink now pushes onto the host stack (see openEntity /
        // onOpenPlace) — the old local `.sheet(selectedEntitySlug)` is gone.
        // Issue #837: memo 锚定 AI 对话——Drop-to-Ask 拖拽与 ask-past CTA
        // 汇入同一个 sheet。entityDisplayNames 复用实体墨迹的异步解析结果，
        // 喂给对话的 retrieving 阶段文案与建议问题。
        .sheet(isPresented: $showMemoChat) {
            MemoChatView(
                memo: memo,
                entityDisplayNames: entityDisplayNames,
                onClose: { showMemoChat = false }
            )
            .presentationDetents([.fraction(0.85), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showShareSheet) {
            // Reuse the app-wide ShareSheet wrapper (Settings/ObsidianExport
            // already ships it). Markdown is folded to plain text — raw
            // `**` asterisks leaking into shared text read as broken.
            ShareSheet(activityItems: [MemoMarkdown.plainText(memo.body)])
        }
        .sheet(item: $sharePayload) { payload in
            ShareCardSheet(payload: payload)
        }
        .confirmationDialog(
            NSLocalizedString(
                "memo.detail.delete.title",
                value: "Delete this memo?",
                comment: "Detail view — delete confirmation title"
            ),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(
                NSLocalizedString(
                    "memo.detail.delete.confirm",
                    value: "Delete",
                    comment: "Detail view — delete confirmation destructive action"
                ),
                role: .destructive
            ) {
                Haptics.warningNotification()
                vm.deleteMemo(memo)
                dismiss()
            }
            Button(
                NSLocalizedString(
                    "memo.detail.delete.cancel",
                    value: "Cancel",
                    comment: "Detail view — delete confirmation cancel"
                ),
                role: .cancel
            ) {}
        } message: {
            Text(NSLocalizedString(
                "memo.detail.delete.warning",
                value: "This cannot be undone.",
                comment: "Detail view — delete confirmation warning body"
            ))
        }
    }

    // MARK: - Body editing

    /// MarkdownEditor manages first-responder itself; SAVE/CANCEL just need
    /// the keyboard gone before the cabin collapses.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    /// Single entry point for both edit affordances (body tap + ellipsis
    /// menu): seed the editor with the *raw* vault text — view mode renders
    /// markdown, edit mode shows exactly what's stored.
    private func startBodyEdit() {
        Haptics.soft()
        editedBody = memo.body
        withAnimation(.easeOut(duration: 0.18)) {
            isEditingBody = true
        }
    }

    // MARK: - Entity Ink (issue #835)

    /// Body text with compiled entity mentions rendered as quiet amber-underlined
    /// links. Mentions that don't literally appear in the text are skipped —
    /// the ink never guesses.
    private func inkedBody(_ text: String) -> AttributedString {
        let polished = CJKTextPolish.polish(text)
        var attr = AttributedString(polished)
        guard !memo.entityMentions.isEmpty else { return attr }

        for slug in memo.entityMentions where !slug.isEmpty {
            // Latin slugs may appear verbatim or space-separated; CJK prose
            // is matched via the wiki page's display name (resolved async).
            // First variant that matches wins.
            var terms = [slug, slug.replacingOccurrences(of: "-", with: " ")]
            if let display = entityDisplayNames[slug], !display.isEmpty {
                terms.insert(display, at: 0)
            }
            for term in terms {
                var matched = false
                var searchRange = polished.startIndex..<polished.endIndex
                while let r = polished.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                ) {
                    matched = true
                    if let ar = Range(r, in: attr) {
                        let encoded = slug.addingPercentEncoding(
                            withAllowedCharacters: .alphanumerics
                        ) ?? slug
                        attr[ar].link = URL(string: "daypage-entity://o?s=\(encoded)")
                        attr[ar].underlineStyle = Text.LineStyle(
                            pattern: .solid,
                            color: DSColor.amberAccent.opacity(0.5)
                        )
                        // Links default to tint blue — keep journal ink.
                        attr[ar].foregroundColor = DSColor.inkPrimary
                    }
                    searchRange = r.upperBound..<polished.endIndex
                }
                if matched { break }
            }
        }
        return attr
    }

    /// Reads each mention's wiki page frontmatter `name:` so display names
    /// can be matched in prose. Slugs with no wiki page simply stay unmapped.
    nonisolated private static func resolveDisplayNames(for slugs: [String]) -> [String: String] {
        var map: [String: String] = [:]
        let wikiBase = VaultInitializer.vaultURL.appendingPathComponent("wiki")
        for slug in slugs {
            for type in ["places", "people", "themes"] {
                let url = wikiBase.appendingPathComponent(type).appendingPathComponent("\(slug).md")
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in content.components(separatedBy: "\n").prefix(12) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("name:") else { continue }
                    let value = trimmed.dropFirst("name:".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !value.isEmpty { map[slug] = value }
                    break
                }
                if map[slug] != nil { break }
            }
        }
        return map
    }

    private func openEntity(slug: String) {
        Haptics.soft()
        let wikiBase = VaultInitializer.vaultURL.appendingPathComponent("wiki")
        var resolvedType = "themes"
        for type in ["places", "people", "themes"] {
            let url = wikiBase.appendingPathComponent(type).appendingPathComponent("\(slug).md")
            if FileManager.default.fileExists(atPath: url.path) {
                resolvedType = type
                break
            }
        }
        // W1: MemoDetail is always pushed onto a host stack (Today/Archive/
        // Daily), so push the entity onto that stack instead of opening a local
        // sheet — it inherits system back + edge-pop and can recurse.
        // sourceDateString = memo's date, so the entity page shows the "from
        // {date}" breadcrumb the old .sheet passed (preserved across W1).
        nav.push(
            EntityRef(
                type: resolvedType,
                slug: slug,
                sourceDateString: DateFormatters.isoDate.string(from: memo.created)
            ),
            in: nav.selectedTab
        )
    }

    // MARK: - Echoes navigation

    /// Same dismiss-then-post pattern as EntityPageView's backlink rows: the
    /// 200ms defer lets the pop animation land before `.openArchiveAt`
    /// re-routes the app to that day.
    private func openEcho(_ dateString: String) {
        Haptics.soft()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(
                name: .openArchiveAt,
                object: nil,
                userInfo: ["date": dateString]
            )
        }
    }
}

// MARK: - DetailVoiceSection

private struct DetailVoiceSection: View {
    let attachment: Memo.Attachment

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            sectionLabel(NSLocalizedString("memo.detail.section.voice", comment: ""))
            let audioURL = VaultInitializer.vaultURL.appendingPathComponent(attachment.file)
            VoiceMemoPlayerRow(
                fileURL: audioURL,
                duration: attachment.duration ?? 0,
                transcript: attachment.transcript,
                transcriptionStatus: attachment.transcriptionStatus
            )
            .frame(maxWidth: .infinity)
            .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
        }
    }
}

// MARK: - DetailPhotoSection

private struct DetailPhotoSection: View {
    let attachment: Memo.Attachment
    @State private var exifText: String?
    @Binding var fullResImage: UIImage?
    @Binding var showFullscreen: Bool

    @State private var loadedImage: UIImage?

    private var photoURL: URL {
        VaultInitializer.vaultURL.appendingPathComponent(attachment.file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            sectionLabel(NSLocalizedString("memo.detail.section.photo", comment: ""))

            ZStack(alignment: .bottom) {
                Group {
                    if let img = loadedImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, minHeight: 240)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(DSColor.glassLo)
                            .frame(maxWidth: .infinity, minHeight: 240)
                            .overlay(ProgressView().tint(DSColor.inkSubtle))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                .onTapGesture {
                    fullResImage = loadedImage
                    showFullscreen = true
                }

                // EXIF overlay
                if let exif = exifText {
                    Text(exif)
                        .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.bgWarm.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, DSSpacing.md)
                        .padding(.vertical, DSSpacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(
                                colors: [Color.clear, Color.black.opacity(0.45)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                        )
                }
            }
            .task(id: photoURL) {
                loadedImage = await loadFullResImage(from: photoURL)
                // EXIF caption loads off-main with the image — as a computed
                // property it re-read the file header on every body pass.
                let url = photoURL
                let file = attachment.file
                exifText = await Task.detached(priority: .utility) {
                    Self.exifOverlayText(file: file, photoURL: url)
                }.value
            }

            // Tap hint
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                Text(NSLocalizedString("memo.detail.photo.tap_fullscreen", comment: ""))
                    .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                    .tracking(0.4)
            }
            .foregroundColor(DSColor.inkMuted)
            .textCase(.uppercase)
        }
    }

    nonisolated private static func exifOverlayText(file: String, photoURL: URL) -> String? {
        let filename = URL(fileURLWithPath: file).lastPathComponent.uppercased()
        if let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            var parts: [String] = [filename]
            if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                parts.append("\(Int(focal))mm")
            }
            if let aperture = exif[kCGImagePropertyExifFNumber as String] as? Double {
                parts.append(String(format: "f/%.1f", aperture))
            }
            if let shutter = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                let denom = Int(1.0 / shutter)
                parts.append("1/\(denom)s")
            }
            return parts.joined(separator: "  //  ")
        }
        return filename
    }

    private func loadFullResImage(from url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
    }
}

// MARK: - DetailLocationSection

private struct DetailLocationSection: View {
    let location: Memo.Location?
    var memoDateString: String = ""
    var onOpenPlace: ((String) -> Void)? = nil

    /// "4TH VISIT · LAST 2026-03-18" — the map stops being a coordinate proof
    /// and becomes your relationship with the place (issue #835). Computed
    /// from the in-memory SearchIndex; silently absent until it's warm.
    @State private var visitLine: String?
    /// Non-nil once the place resolves to an existing wiki page — gates the
    /// tap-through affordance so the name is never a dead button.
    @State private var placeSlug: String?

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = location?.lat, let lng = location?.lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            sectionLabel(NSLocalizedString("memo.detail.section.location", comment: ""))

            VStack(alignment: .leading, spacing: 0) {
                // Map preview
                if let coord = coordinate {
                    // 180pt keeps the map a contextual footnote — at 260 it
                    // dominated the page over the journal text itself. Top-only
                    // corners: the map sits flush inside the card, so rounding
                    // its bottom edge opened hairline gaps mid-card.
                    MapPreviewView(coordinate: coord)
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: DSRadius.md,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: DSRadius.md,
                            style: .continuous
                        ))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                            .fill(DSColor.glassLo)
                            .frame(maxWidth: .infinity, minHeight: 120)
                        VStack(spacing: 6) {
                            Image(systemName: "map")
                                .font(.system(size: 28))
                                .foregroundColor(DSColor.inkMuted)
                            Text(NSLocalizedString("memo.detail.location.no_coordinates", comment: ""))
                                .font(DSType.bodySM)
                                .foregroundColor(DSColor.inkMuted)
                        }
                    }
                }

                // Location name + coords + place story
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    if let name = location?.name, !name.isEmpty {
                        Button {
                            guard let slug = placeSlug else { return }
                            Haptics.soft()
                            onOpenPlace?(slug)
                        } label: {
                            HStack(spacing: 6) {
                                Text(name)
                                    .font(DSType.serifBody16)
                                    .foregroundColor(DSColor.inkPrimary)
                                if placeSlug != nil {
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(DSColor.accentOnBg.opacity(0.65))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(placeSlug == nil)
                    }
                    if let coord = coordinate {
                        Text(String(format: "%.5f°, %.5f°", coord.latitude, coord.longitude))
                            .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                            .foregroundColor(DSColor.inkMuted)
                            .tracking(0.4)
                    }
                    if let visitLine {
                        Text(visitLine)
                            .font(DSFonts.jetBrainsMono(size: 10))
                            .tracking(0.6)
                            .foregroundColor(DSColor.accentOnBg.opacity(0.75))
                            .padding(.top, 4)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, DSSpacing.md)

                Divider().background(DSColor.glassRim).padding(.horizontal, 14)

                // Open in Apple Maps
                Button(action: openInMaps) {
                    HStack(spacing: 10) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DSColor.accentOnBg)
                        Text(NSLocalizedString("memo.detail.location.open_maps", comment: ""))
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.accentOnBg)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DSColor.inkMuted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                // #150 press feedback for the "open in Maps" row.
                .pressScale(scale: 0.98,
                            animation: .spring(response: 0.22, dampingFraction: 0.72))
                .disabled(coordinate == nil)
            }
            .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
        }
        .task(id: memoDateString) { await loadPlaceStory() }
    }

    /// Visit count from SearchIndex (in-memory, zero disk); place tap-through
    /// gated on the wiki page actually existing. Both absent = zero UI.
    private func loadPlaceStory() async {
        guard let name = location?.name, !name.isEmpty else { return }

        if !memoDateString.isEmpty, let docs = SearchIndex.shared.documentsIfBuilt() {
            let folded = SearchService.foldForSearch(name)
            let visitDays = docs
                .filter { day in day.memos.contains { $0.foldedLocationName == folded } }
                .map(\.dateString)
                .sorted()
            // Count = prior visit days + this one, so the line stays right
            // even if today's write hasn't reached the index yet.
            let priorDays = visitDays.filter { $0 < memoDateString }
            if priorDays.isEmpty {
                withAnimation(.easeOut(duration: 0.25)) { visitLine = "FIRST VISIT HERE" }
            } else if let previous = priorDays.last {
                withAnimation(.easeOut(duration: 0.25)) {
                    visitLine = "\(Self.ordinal(priorDays.count + 1)) VISIT · LAST \(previous)"
                }
            }
        }

        let slug = EntityPageService.sanitizeSlug(name)
        let url = VaultInitializer.vaultURL
            .appendingPathComponent("wiki/places/\(slug).md")
        if FileManager.default.fileExists(atPath: url.path) {
            placeSlug = slug
        }
    }

    private static func ordinal(_ n: Int) -> String {
        switch n % 100 {
        case 11, 12, 13: return "\(n)TH"
        default:
            switch n % 10 {
            case 1:  return "\(n)ST"
            case 2:  return "\(n)ND"
            case 3:  return "\(n)RD"
            default: return "\(n)TH"
            }
        }
    }

    private func openInMaps() {
        guard let coord = coordinate,
              let url = URL(string: "maps://?ll=\(coord.latitude),\(coord.longitude)") else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - DetailFilesSection

private struct DetailFilesSection: View {
    let attachments: [Memo.Attachment]

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            sectionLabel("Files")

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(attachments.enumerated()), id: \.element.file) { index, att in
                    if index > 0 {
                        Divider().background(DSColor.glassRim).padding(.leading, 44)
                    }
                    DetailFileRow(attachment: att)
                }
            }
            .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
        }
    }
}

// MARK: - DetailFileRow

private struct DetailFileRow: View {
    let attachment: Memo.Attachment

    @State private var fileSize: String = ""
    @State private var previewItem: PreviewFileItem?

    private var fileURL: URL {
        VaultInitializer.vaultURL.appendingPathComponent(attachment.file)
    }

    private var fileName: String {
        attachment.transcript ?? fileURL.lastPathComponent
    }

    private var fileIcon: String {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "pdf":                              return "doc.richtext.fill"
        case "jpg", "jpeg", "png", "heic":      return "photo.fill"
        case "mp4", "mov", "m4v":               return "video.fill"
        case "mp3", "m4a", "wav", "aac":        return "music.note"
        case "zip", "tar", "gz":                return "archivebox.fill"
        case "txt", "md":                       return "doc.text.fill"
        case "xls", "xlsx", "csv":              return "tablecells.fill"
        case "doc", "docx":                     return "doc.fill"
        default:                                return "doc.fill"
        }
    }

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DSColor.amberSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(DSColor.amberRim, lineWidth: 0.5)
                    )
                    .frame(width: 32, height: 32)
                Image(systemName: fileIcon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(DSColor.accentOnBg)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !fileSize.isEmpty {
                    Text(fileSize)
                        .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                        .foregroundColor(DSColor.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: openFile) {
                Text("Open")
                    .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.accentOnBg)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DSColor.amberSoft)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
            }
            // #150 press feedback for the "Open" attachment pill.
            .pressScale(scale: 0.96, opacity: 0.9,
                        animation: .spring(response: 0.2, dampingFraction: 0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, DSSpacing.md)
        .onAppear { loadFileSize() }
        .sheet(item: $previewItem) { item in
            FilePreviewSheet(url: item.url)
                .ignoresSafeArea()
        }
    }

    private func loadFileSize() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let bytes = attrs[.size] as? Int64 else { return }
        fileSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func openFile() {
        // In-app QuickLook — `UIApplication.shared.open(fileURL)` hands the
        // sandboxed URL to an external app with no read access, which renders
        // a blank/incomplete document.
        previewItem = PreviewFileItem(url: fileURL)
    }
}

// MARK: - DetailMetadataSection

private struct DetailMetadataSection: View {
    let memo: Memo

    /// Photo EXIF rows resolved off-main. Reading image properties inline in
    /// `kindSpecificRows` was synchronous disk I/O on every body pass.
    @State private var photoExifRows: [(label: String, value: String)] = []

    private var createdFull: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: memo.created)
    }

    private var vaultFilePath: String {
        "vault/raw/\(DateFormatters.isoDate.string(from: memo.created)).md"
    }

    // MARK: - Body stats

    private struct BodyStats {
        let wordCount: Int
        let charCount: Int
        let readingMinutes: Int  // 0 means "< 1 min"
    }

    private func bodyStats(for text: String) -> BodyStats {
        var cjkCount = 0
        var latinWords = 0
        var inLatinRun = false
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0x3040...0x30FF).contains(scalar.value) {
                cjkCount += 1
                inLatinRun = false
            } else if scalar.properties.isWhitespace {
                inLatinRun = false
            } else {
                if !inLatinRun { latinWords += 1 }
                inLatinRun = true
            }
        }
        // Reading time: CJK at 300 cpm, Latin at 220 wpm — sum independent estimates
        let totalMinutes = Double(cjkCount) / 300.0 + Double(latinWords) / 220.0
        return BodyStats(
            wordCount: TextCount.words(text),
            charCount: text.count,
            readingMinutes: Int(totalMinutes.rounded())
        )
    }

    var body: some View {
        let bodyTrimmed = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Metadata")
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkMuted)
                .tracking(1.2)
                .textCase(.uppercase)
                .padding(.bottom, DSSpacing.xs)

            metaRow(label: "Created", value: createdFull)
            metaRow(label: "File", value: vaultFilePath)
            metaRow(label: "Kind", value: memo.type.rawValue.capitalized)

            // Body stats — only shown when there is actual body text
            if !bodyTrimmed.isEmpty {
                let stats = bodyStats(for: bodyTrimmed)
                // Pure-CJK text tokenizes one word per character, so the two
                // rows would repeat the same number — show words only when
                // the counts actually diverge.
                if stats.wordCount != stats.charCount {
                    metaRow(
                        label: NSLocalizedString("memo.detail.meta.words", comment: ""),
                        value: "\(stats.wordCount)"
                    )
                }
                metaRow(
                    label: NSLocalizedString("memo.detail.meta.characters", comment: ""),
                    value: "\(stats.charCount)"
                )
                let readingValue: String = stats.readingMinutes < 1
                    ? NSLocalizedString("memo.detail.meta.reading.less_than_1", comment: "")
                    : String(format: NSLocalizedString("memo.detail.meta.reading.min", comment: ""), stats.readingMinutes)
                metaRow(
                    label: NSLocalizedString("memo.detail.meta.reading", comment: ""),
                    value: readingValue
                )
            }

            // Kind-specific fields
            kindSpecificRows
        }
        .task(id: memo.id) {
            guard let photoAtt = memo.attachments.first(where: { $0.kind == "photo" }) else { return }
            let url = VaultInitializer.vaultURL.appendingPathComponent(photoAtt.file)
            photoExifRows = await Task.detached(priority: .utility) {
                Self.loadPhotoExifRows(from: url)
            }.value
        }
    }

    /// Metadata-only image header read (no pixel decode) — still disk I/O,
    /// so it runs off the main actor via the .task above.
    nonisolated private static func loadPhotoExifRows(from photoURL: URL) -> [(label: String, value: String)] {
        guard let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return []
        }
        var rows: [(label: String, value: String)] = []
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let aperture = exif[kCGImagePropertyExifFNumber as String] as? Double {
                rows.append(("Aperture", String(format: "f/%.1f", aperture)))
            }
            if let shutter = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                let denom = Int(1.0 / shutter)
                rows.append(("Shutter", "1/\(denom)s"))
            }
            if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
               let isoVal = iso.first {
                rows.append(("ISO", "\(isoVal)"))
            }
            if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                rows.append(("Focal Length", "\(Int(focal))mm"))
            }
        }
        if let w = props[kCGImagePropertyPixelWidth as String] as? Int,
           let h = props[kCGImagePropertyPixelHeight as String] as? Int {
            rows.append(("Dimensions", "\(w) × \(h)"))
        }
        return rows
    }

    @ViewBuilder
    private var kindSpecificRows: some View {
        // Voice: duration + transcription provider
        if let audioAtt = memo.attachments.first(where: { $0.kind == "audio" }) {
            if let dur = audioAtt.duration {
                metaRow(label: "Duration", value: dur.mmss)
            }
            if let transcript = audioAtt.transcript, !transcript.isEmpty {
                metaRow(label: "Transcription", value: "OpenAI Whisper")
            } else {
                metaRow(label: "Transcription", value: "Pending")
            }
        }

        // Photo: EXIF fields — rendered from state; resolved off-main in .task.
        ForEach(photoExifRows, id: \.label) { row in
            metaRow(label: row.label, value: row.value)
        }

        // Location: coordinates
        if let loc = memo.location {
            if let lat = loc.lat, let lng = loc.lng {
                metaRow(label: "Coordinates", value: String(format: "%.6f, %.6f", lat, lng))
            }
            if let name = loc.name, !name.isEmpty {
                metaRow(label: "Place", value: name)
            }
        }

        // Weather
        if let weather = memo.weather, !weather.isEmpty {
            metaRow(label: "Weather", value: weather)
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Text(label.uppercased())
                .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                .tracking(0.6)
                .foregroundColor(DSColor.inkMuted)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                .tracking(0.4)
                .foregroundColor(DSColor.inkMuted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - PhotoFullscreenView

struct PhotoFullscreenView: View {
    let image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                    // #150 press feedback for the fullscreen photo close button.
                    // respectsReduceMotion: false — this overlay never consulted
                    // the accessibility env before; keep the dip subtle but present.
                    .pressScale(scale: 0.92,
                                animation: .spring(response: 0.2, dampingFraction: 0.7))
                    .padding(.trailing, DSSpacing.xl)
                    .padding(.top, DSSpacing.xl)
                }
                Spacer()
            }
        }
    }
}

// MARK: - EchoesSection (issue #835)

/// "8 个月前的深夜，你也在改档案页" — related memories surfaced by entity
/// overlap. Pure-local raw-vault scan (same mechanism EntityPageView uses for
/// backlinks), run detached; renders nothing when the memo has no compiled
/// mentions or no kin, so the page never shows an empty shell.
private struct EchoesSection: View {
    let memo: Memo
    let onOpen: (String) -> Void

    struct Echo: Identifiable, Equatable {
        let id: String
        let dateString: String
        let snippet: String
    }

    @State private var echoes: [Echo] = []

    var body: some View {
        // Always-present container: a `Group { if … }` whose condition starts
        // false has NO child view, so a `.task` hung on it never fires and
        // the section could never populate. The VStack exists (zero-size)
        // either way, keeping the loader alive while the empty state stays
        // invisible — top padding is also gated so absence costs 0pt.
        VStack(alignment: .leading, spacing: 8) {
            if !echoes.isEmpty {
                    sectionLabel(NSLocalizedString(
                        "memo.detail.section.echoes",
                        value: "Echoes",
                        comment: "Detail view — related-memories section label"
                    ))

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(echoes.enumerated()), id: \.element.id) { index, echo in
                            if index > 0 {
                                Divider()
                                    .background(DSColor.glassRim)
                                    .padding(.leading, 14)
                            }
                            Button {
                                onOpen(echo.dateString)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(echo.dateString)
                                        .font(DSFonts.jetBrainsMono(size: 10))
                                        .tracking(0.4)
                                        .foregroundColor(DSColor.inkSubtle)
                                        .layoutPriority(1)
                                    Text(echo.snippet)
                                        .font(DSFonts.serif(size: 14, weight: .regular, relativeTo: .subheadline))
                                        .foregroundColor(DSColor.inkMuted)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(DSColor.inkSubtle.opacity(0.6))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
            }
        }
        .padding(.top, echoes.isEmpty ? 0 : 28)
        .task(id: memo.id) {
            let target = memo
            let found = await Task.detached(priority: .utility) {
                Self.findEchoes(for: target)
            }.value
            withAnimation(.easeOut(duration: 0.25)) { echoes = found }
        }
    }

    /// Entity-overlap retrieval. `entityMentions` (post-compilation) is the
    /// authoritative match key; body-contains is the fallback for days not
    /// yet compiled. Same-day memos are excluded — an echo is a different day.
    nonisolated private static func findEchoes(for memo: Memo) -> [Echo] {
        let slugs = memo.entityMentions.filter { !$0.isEmpty }
        guard !slugs.isEmpty else { return [] }

        let ownDate = DateFormatters.isoDate.string(from: memo.created)
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rawDir, includingPropertiesForKeys: nil
        ) else { return [] }

        struct Candidate {
            let dateString: String
            let snippet: String
            let shared: Int
        }
        var candidates: [Candidate] = []

        for file in files where file.pathExtension == "md" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard stem != ownDate,
                  stem.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  let content = try? String(contentsOf: file, encoding: .utf8),
                  slugs.contains(where: { content.contains($0) })
            else { continue }

            for m in RawStorage.parse(fileContent: content) where m.id != memo.id {
                let shared = slugs.filter { s in
                    m.entityMentions.contains(s) || m.body.contains(s)
                }.count
                guard shared > 0 else { continue }
                let snippet = m.body
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                guard !snippet.isEmpty else { continue }
                candidates.append(Candidate(
                    dateString: stem,
                    snippet: String(snippet.prefix(72)),
                    shared: shared
                ))
            }
        }

        // One echo per day: several hits from the same day crowd out other
        // eras, and an echo's value is the span of time it bridges.
        var bestPerDay: [String: Candidate] = [:]
        for c in candidates where (bestPerDay[c.dateString]?.shared ?? -1) < c.shared {
            bestPerDay[c.dateString] = c
        }
        return bestPerDay.values
            .sorted { ($0.shared, $0.dateString) > ($1.shared, $1.dateString) }
            .prefix(3)
            .enumerated()
            .map { index, c in
                Echo(id: "\(c.dateString)-\(index)", dateString: c.dateString, snippet: c.snippet)
            }
    }
}

// MARK: - Section label helper

private func sectionLabel(_ title: String) -> some View {
    Text(title.uppercased())
        .font(DSType.mono10)
        .foregroundColor(DSColor.inkMuted)
        .tracking(1.2)
}
