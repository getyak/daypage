import SwiftUI
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - RawMemoView

/// 显示某一天的所有原始 memo，按时间排序。
/// 用于原始 memo 标签页；是否尚无 Daily Page 由父视图解析。
struct RawMemoView: View {

    let dateString: String
    let showsUncompiledBadge: Bool

    @EnvironmentObject private var nav: AppNavigationModel
    @State private var memos: [Memo] = []
    @State private var isLoading: Bool = true

    private var formattedDate: String {
        guard let date = DateFormatters.isoDate.date(from: dateString) else { return dateString }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date).uppercased()
    }

    var body: some View {
        // DayDetailView owns the navigation stack and back gesture. Nesting
        // another stack here can leave raw-only days blank on first display.
        ZStack {
            DSColor.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().background(DSColor.outline)
                content
            }
        }
        .task(id: dateString) { loadMemos() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // intentionally-untranslated: archival tag (FINDING-010 —
                // English mono caps are reserved for archival labels)
                Text("RAW MEMOS")
                    .font(.custom("SpaceGrotesk-Bold", size: 16))
                    .foregroundColor(DSColor.onSurface)
                    .kerning(2)
                Text(formattedDate)
                    .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }

            Spacer()

            if showsUncompiledBadge {
                StatusBadge(label: "UNCOMPILED", style: .metadata)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer()
            ProgressView()
                .tint(DSColor.onSurfaceVariant)
            Spacer()
        } else if memos.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundColor(DSColor.onSurfaceVariant.opacity(0.5))
                Text(NSLocalizedString("rawmemo.empty", comment: "Empty state: no raw memos exist for this day"))
                    .font(DSFonts.spaceGrotesk(size: 14, weight: .bold, relativeTo: .subheadline))
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(memos.enumerated()), id: \.element.id) { idx, memo in
                        TimelineRow(
                            memo: memo,
                            isLast: idx == memos.count - 1,
                            onOpen: {
                                // Resolve in the day file being displayed, even
                                // when a historical memo's timestamp differs.
                                // The owning raw day key is already known and
                                // preserved; never re-derive it from `created`.
                                guard let ref = MemoDetailRef(
                                    id: memo.id,
                                    dayString: dateString,
                                    source: .raw
                                ) else { return }
                                nav.push(ref, in: nav.selectedTab)
                            }
                        )
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Data Loading

    private func loadMemos() {
        isLoading = true
        guard RawStorage.isValidDayString(dateString) else {
            DayPageLogger.shared.error("RawMemoView: invalid dateString '\(dateString)'")
            memos = []
            isLoading = false
            return
        }

        let url = VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("\(dateString).md")
        guard FileManager.default.fileExists(atPath: url.path) else {
            DayPageLogger.shared.error("RawMemoView: raw file missing at \(url.path) errno=\(errno)")
            memos = []
            isLoading = false
            return
        }

        let loaded: [Memo]
        do {
            loaded = try RawStorage.read(dayString: dateString, vaultRoot: VaultInitializer.vaultURL)
        } catch {
            DayPageLogger.shared.error("RawMemoView: read \(url.path) errno=\(errno): \(error)")
            loaded = []
        }
        memos = loaded.sorted { $0.created < $1.created }
        isLoading = false
    }
}
