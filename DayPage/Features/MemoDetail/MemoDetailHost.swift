import SwiftUI
import DayPageModels
import DayPageStorage

/// Resolves a stable navigation reference into the current Vault record and
/// owns mutation state.  The detail screen never reaches back into Today or
/// Daily list models, so list refreshes cannot invalidate an in-flight route.
struct MemoDetailHost: View {
    private enum LoadState: Equatable {
        case loading
        case ready(Memo)
        case unavailable(String)
    }

    let reference: MemoDetailRef

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading

    var body: some View {
        ZStack {
            AmbientBackground().ignoresSafeArea()

            switch state {
            case .loading:
                ProgressView()
                    .tint(DSColor.accentOnBg)
                    .accessibilityLabel(Text(NSLocalizedString(
                        "memo.detail.loading", value: "Loading memo",
                        comment: "Memo detail loading accessibility label"
                    )))

            case .ready(let memo):
                MemoDetailView(
                    memo: memo,
                    backLabel: reference.source.backLabel,
                    owningFileKey: reference.dayString,
                    onUpdateBody: updateBody,
                    onDelete: deleteMemo,
                    onRestore: restoreMemo,
                    onMemoChanged: memoDidChange
                )

            case .unavailable(let message):
                MemoDetailUnavailableView(message: message, onClose: { dismiss() })
            }
        }
        .task(id: reference) { await load() }
        .bannerOverlay(topInset: 8)
    }

    private func load() async {
        state = .loading
        SentryReporter.breadcrumb(
            category: "memo-detail.route",
            message: "detail route started source=\(reference.source)"
        )
        do {
            let memo = try await MemoRecordStore.shared.memo(
                id: reference.id,
                dayString: reference.dayString
            )
            guard !Task.isCancelled else { return }
            state = .ready(memo)
            let photos = memo.attachments.lazy.filter { $0.kind == "photo" }.count
            let audio = memo.attachments.lazy.filter { $0.kind == "audio" }.count
            SentryReporter.breadcrumb(
                category: "memo-detail.route",
                message: "detail loaded kind=\(memo.type.rawValue) photos=\(photos) audio=\(audio)"
            )
        } catch {
            guard !Task.isCancelled else { return }
            state = .unavailable(error.localizedDescription)
            SentryReporter.breadcrumb(
                category: "memo-detail.route",
                level: .error,
                message: "detail load failed type=\(String(describing: type(of: error)))"
            )
        }
    }

    private func updateBody(_ body: String) async throws -> Memo {
        try await MemoRecordStore.shared.updateBody(
            id: reference.id,
            dayString: reference.dayString,
            body: body
        )
    }

    private func deleteMemo() async throws {
        try await MemoRecordStore.shared.delete(id: reference.id, dayString: reference.dayString)
    }

    private func restoreMemo(_ memo: Memo) async throws {
        try await MemoRecordStore.shared.restore(memo, dayString: reference.dayString)
    }

    private func memoDidChange(_ memo: Memo) {
        state = .ready(memo)
    }
}

private struct MemoDetailUnavailableView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: DSSpacing.lg) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(DSColor.inkMuted)
            Text(NSLocalizedString(
                "memo.detail.unavailable", value: "This memo is unavailable",
                comment: "Memo detail unavailable title"
            ))
            .font(DSType.h2)
            .foregroundColor(DSColor.inkPrimary)
            Text(message)
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkMuted)
                .multilineTextAlignment(.center)
            Button(NSLocalizedString("common.close", value: "Close", comment: "Close button")) {
                onClose()
            }
            .buttonStyle(.bordered)
        }
        .padding(DSSpacing.xl2)
    }
}
