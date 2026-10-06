import SwiftUI
import DayPageModels
import DayPageServices

/// Presentation shell for one already-resolved memo. Storage ownership lives
/// in `MemoDetailHost`; expensive, disposable decorations live in
/// `MemoDetailDerivedDataLoader`; media decoding lives in the image pipeline.
struct MemoDetailView: View {
    let memo: Memo
    let backLabel: String
    /// Owning raw file key (`YYYY-MM-DD`) supplied by `MemoDetailHost` from the
    /// validated route ref, so FILE metadata displays the exact owning file
    /// even when a preferred-time-zone change would re-date `memo.created`.
    /// Optional only to preserve standalone construction (previews/tests)
    /// without a host route; that fallback keeps the legacy created-derived key.
    var owningFileKey: String? = nil
    let onUpdateBody: (String) async throws -> Memo
    let onDelete: () async throws -> Void
    let onRestore: (Memo) async throws -> Void
    let onMemoChanged: (Memo) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var nav: AppNavigationModel
    @ObservedObject private var appSettings = AppSettings.shared

    @State private var derivedData = MemoDetailDerivedData.empty
    @State private var isEditingBody = false
    @State private var showDeleteConfirmation = false
    @State private var showTextShare = false
    @State private var showMemoChat = false
    @State private var sharePayload: SharePayload?
    @State private var photoViewerItem: MemoPhotoViewerItem?
    @State private var errorMessage: String?

    private var kickerText: String {
        MemoDetailDatePresentation.kicker(memo.created, timeZone: appSettings.preferredTimeZone)
    }

    private var quoteAttribution: String {
        var value = DateFormatters.isoDate.string(from: memo.created)
        if let name = memo.location?.name, !name.isEmpty { value += " · \(name)" }
        return value
    }

    var body: some View {
        ZStack(alignment: .top) {
            AmbientBackground().ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    navigationRow
                    Text(kickerText)
                        .font(DSType.mono10)
                        .foregroundColor(DSColor.inkMuted)
                        .tracking(1.2)
                        .padding(.bottom, 14)

                    MemoDetailBodySection(
                        memo: memo,
                        entityDisplayNames: derivedData.entityDisplayNames,
                        isEditing: $isEditingBody,
                        onOpenEntity: openEntity,
                        onSave: saveBody
                    )

                    marginNote

                    MemoDetailAttachmentsSection(
                        memo: memo,
                        derivedData: derivedData,
                        onOpenPhoto: { photoViewerItem = $0 },
                        onOpenPlace: { openEntity(slug: $0, forcedType: "places") }
                    )

                    MemoDetailEchoesSection(echoes: derivedData.echoes, onOpen: openEcho)
                    askPastButton

                    Divider()
                        .background(DSColor.inkFaint)
                        .padding(.vertical, DSSpacing.xl)

                    MemoDetailMetadataSection(
                        memo: memo,
                        photoMetadataByFile: derivedData.photoMetadataByFile,
                        // Owning file key comes from the Host's validated
                        // route — never recomputed from `memo.created` under a
                        // new time zone.
                        owningFileKey: owningFileKey
                            ?? DateFormatters.isoDate.string(from: memo.created)
                    )
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, DSSpacing.xl2)
                .padding(.bottom, 32)
            }
            .dropToAsk(
                isEnabled: !isEditingBody,
                onAsk: { showMemoChat = true },
                onCommitBack: { dismiss() }
            )
        }
        .navigationBarHidden(true)
        .onAppear {
            AnalyticsService.shared.record(
                AnalyticsService.Name.detailOpened,
                props: ["memo_id": memo.id.uuidString]
            )
            #if DEBUG
            if qaFlag("qaDeleteOpenMemo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    deleteMemo()
                }
            }
            #endif
        }
        .task(id: memo) {
            let loaded = await MemoDetailDerivedDataLoader.load(for: memo)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { derivedData = loaded }
        }
        .fullScreenCover(item: $photoViewerItem) { MemoPhotoFullscreenView(item: $0) }
        .sheet(isPresented: $showMemoChat) {
            MemoChatView(
                memo: memo,
                entityDisplayNames: derivedData.entityDisplayNames,
                onClose: { showMemoChat = false }
            )
            .presentationDetents([.fraction(0.85), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTextShare) {
            ShareSheet(activityItems: [MemoMarkdown.plainText(memo.body)])
        }
        .sheet(item: $sharePayload) { ShareCardSheet(payload: $0) }
        .confirmationDialog(
            NSLocalizedString(
                "memo.detail.delete.title", value: "Delete this memo?",
                comment: "Detail view — delete confirmation title"
            ),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                NSLocalizedString(
                    "memo.detail.delete.confirm", value: "Delete",
                    comment: "Detail view — delete confirmation destructive action"
                ),
                role: .destructive,
                action: deleteMemo
            )
            Button(
                NSLocalizedString(
                    "memo.detail.delete.cancel", value: "Cancel",
                    comment: "Detail view — delete confirmation cancel"
                ),
                role: .cancel
            ) {}
        } message: {
            Text(NSLocalizedString(
                "memo.detail.delete.warning", value: "You can undo for a few seconds after deleting.",
                comment: "Detail view — delete confirmation warning body"
            ))
        }
        .alert(
            NSLocalizedString("common.error", value: "Error", comment: "Error alert title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var navigationRow: some View {
        HStack {
            Button { dismiss() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                    Text(backLabel).font(DSType.bodySM)
                }
                .foregroundColor(DSColor.inkMuted)
            }
            .pressScale(scale: 0.97, offsetY: 0.5,
                        animation: .spring(response: 0.2, dampingFraction: 0.7))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(backLabel))

            Spacer()
            actionMenu
        }
        .padding(.top, DSSpacing.lg)
        .padding(.bottom, DSSpacing.xl)
    }

    private var actionMenu: some View {
        Menu {
            Button { isEditingBody = true } label: {
                Label(NSLocalizedString(
                    "memo.detail.action.edit", value: "Edit Body",
                    comment: "Detail view — menu: edit body"
                ), systemImage: "pencil")
            }
            Button {
                UIPasteboard.general.string = memo.body
                Haptics.tapConfirm()
            } label: {
                Label(NSLocalizedString(
                    "memo.detail.action.copy", value: "Copy Text",
                    comment: "Detail view — menu: copy body"
                ), systemImage: "doc.on.doc")
            }
            Button {
                Haptics.soft()
                sharePayload = SharePayload.auto(from: memo)
            } label: {
                Label(NSLocalizedString(
                    "memo.detail.action.shareCard", value: "Share as Card",
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
                    "memo.detail.action.shareQuote", value: "Share as Quote",
                    comment: "Detail view — menu: share as quote card"
                ), systemImage: "quote.opening")
            }
            Button {
                Haptics.soft()
                showTextShare = true
            } label: {
                Label(NSLocalizedString(
                    "memo.detail.action.share", value: "Share as Text",
                    comment: "Detail view — menu: share plain text"
                ), systemImage: "text.alignleft")
            }
            Divider()
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label(NSLocalizedString(
                    "memo.detail.action.delete", value: "Delete Memo",
                    comment: "Detail view — menu: delete"
                ), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
                .foregroundColor(DSColor.inkMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(
            "memo.detail.a11y.menu", value: "更多操作",
            comment: "Detail view — ellipsis menu accessibility label"
        ))
    }

    @ViewBuilder
    private var marginNote: some View {
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
        }
    }

    private var askPastButton: some View {
        Button {
            Haptics.tapConfirm()
            showMemoChat = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                Text(NSLocalizedString(
                    "memo.detail.ask_past", value: "Ask your past self",
                    comment: "Detail view — ask-past-self CTA label"
                ))
                .font(DSType.bodySM)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.65)
            }
            .foregroundColor(DSColor.accentOnBg)
            .padding(.horizontal, 14)
            .padding(.vertical, DSSpacing.md)
            .amberPillSurface(RoundedRectangle(cornerRadius: DSRadius.md))
        }
        .pressScale(scale: 0.98, opacity: 0.92,
                    animation: .spring(response: 0.25, dampingFraction: 0.72))
        .accessibilityIdentifier("memo.detail.ask.past")
        .padding(.top, 28)
    }

    private func saveBody(_ body: String) async -> Bool {
        do {
            let updated = try await onUpdateBody(body)
            onMemoChanged(updated)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func deleteMemo() {
        Haptics.warningNotification()
        Task {
            do {
                try await onDelete()
                showDeleteUndoBanner()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func showDeleteUndoBanner() {
        let deletedMemo = memo
        BannerCenter.shared.show(AppBannerModel(
            kind: .success,
            title: NSLocalizedString(
                "memo.detail.delete.success", value: "Memo deleted",
                comment: "Detail view — memo deleted confirmation"
            ),
            primaryAction: BannerAction(
                label: NSLocalizedString(
                    "memo.detail.delete.undo", value: "Undo",
                    comment: "Detail view — undo memo deletion"
                ),
                handler: {
                    Task { @MainActor in
                        do {
                            try await onRestore(deletedMemo)
                            BannerCenter.shared.show(AppBannerModel(
                                kind: .success,
                                title: NSLocalizedString(
                                    "memo.detail.delete.restored", value: "Memo restored",
                                    comment: "Detail view — deleted memo restored"
                                )
                            ))
                        } catch {
                            BannerCenter.shared.show(AppBannerModel(
                                kind: .error,
                                title: NSLocalizedString(
                                    "memo.detail.delete.restore_failed", value: "Couldn't restore memo",
                                    comment: "Detail view — undo deletion failure"
                                ),
                                subtitle: error.localizedDescription
                            ))
                        }
                    }
                }
            ),
            autoDismiss: true
        ))
    }

    #if DEBUG
    private func qaFlag(_ key: String) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-\(key)"),
              arguments.indices.contains(index + 1) else { return false }
        return ["1", "true", "yes"].contains(arguments[index + 1].lowercased())
    }
    #endif

    private func openEntity(_ slug: String) {
        openEntity(slug: slug, forcedType: nil)
    }

    private func openEntity(slug: String, forcedType: String?) {
        Haptics.soft()
        nav.push(
            EntityRef(
                type: forcedType ?? MemoDetailDerivedDataLoader.entityType(for: slug),
                slug: slug,
                sourceDateString: DateFormatters.isoDate.string(from: memo.created)
            ),
            in: nav.selectedTab
        )
    }

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
