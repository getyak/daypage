import SwiftUI

// MARK: - DailyPageTab

enum DailyPageTab: String, CaseIterable {
    case digest = "DIGEST"
    case timeline = "TIMELINE"
}

// MARK: - DailyPageModel

/// Daily Page Markdown 文件的解析模型。
struct DailyPageModel {
    let dateString: String
    let weekday: String
    let summary: String
    let locationPrimary: String
    let entriesCount: Int
    let rawContent: String        // Full file content
    let sections: [PageSection]
    let locations: [LocationEntry]
    let followUpQuestions: [String]
    let memoCount: Int
    /// Vault 相对路径，指向封面主图（例如 "raw/assets/photo_...jpg"）。
    /// 当日无照片时返回 nil。
    let coverAssetPath: String?
    /// Color-coded narrative threads. Falls back to stub when compile output lacks them.
    let threads: [ThreadEntry]
    /// Entity mention chips. Falls back to stub when compile output lacks them.
    let mentions: [String]

    struct PageSection {
        let title: String
        let body: String
    }

    struct LocationEntry {
        let time: String
        let name: String
        let note: String
    }

    /// A narrative thread with an optional color label.
    struct ThreadEntry {
        let label: String
        let color: Color
    }
}

// MARK: - FlowLayout

/// SwiftUI Layout that wraps subviews to new lines when the line width is exceeded.
struct FlowLayout: Layout {

    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += lineHeight + spacing
                totalHeight = y
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.maxX
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > bounds.minX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - DailyPageMemoVM

/// Lightweight MemoDetailViewModel for archive-date memos in DailyPageView.
@MainActor
final class DailyPageMemoVM: ObservableObject, MemoDetailViewModel {

    @Published var memos: [Memo] = []

    func update(memo: Memo, body: String) {
        guard let idx = memos.firstIndex(where: { $0.id == memo.id }) else { return }
        var updated = memos[idx]
        updated.body = body
        var newMemos = memos
        newMemos[idx] = updated
        try? rewrite(memos: newMemos, referenceDate: memo.created)
        memos = newMemos
        Haptics.commit()
    }

    func deleteMemo(_ memo: Memo) {
        let remaining = memos.filter { $0.id != memo.id }
        try? rewrite(memos: remaining, referenceDate: memo.created)
        memos = remaining
    }

    private func rewrite(memos: [Memo], referenceDate: Date) throws {
        let url = RawStorage.fileURL(for: referenceDate)
        if memos.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        let ordered = memos.sorted { $0.created < $1.created }
        let content = ordered.map { $0.toMarkdown() }.joined(separator: RawStorage.memoSeparator)
        try RawStorage.atomicWrite(string: content, to: url)
    }
}
