import SwiftUI

// MARK: - SearchView

/// Full-screen search panel presented from ``ArchiveView``.
/// Runs an in-memory ``SearchService`` query with a 150 ms debounce and
/// forwards the selected date back to the parent so it can open the Daily Page.
struct SearchView: View {

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputFocused: Bool

    @State private var keyword: String = ""
    @State private var results: [SearchResult] = []
    @State private var hasSearched: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil

    /// Invoked with "yyyy-MM-dd" when the user taps a hit.
    var onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                    Divider().background(DSColor.outlineVariant)

                    contentArea
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                // 延迟一拍确保 sheet 动画完成后再触发键盘，避免闪烁。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(DSColor.onSurfaceVariant)

                TextField("搜索 memo、地点或日期", text: $keyword)
                    .font(.custom("Inter-Regular", size: 14))
                    .foregroundColor(DSColor.onSurface)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($isInputFocused)
                    .submitLabel(.search)
                    .onChange(of: keyword) { _ in scheduleSearch() }

                if !keyword.isEmpty {
                    Button(action: {
                        keyword = ""
                        results = []
                        hasSearched = false
                        isInputFocused = true
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(DSColor.surfaceContainer)
            .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))

            Button(action: { dismiss() }) {
                Text("取消")
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.primary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if !hasSearched {
            idleState
        } else if results.isEmpty {
            emptyState
        } else {
            resultList
        }
    }

    private var idleState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(DSColor.outlineVariant)
            Text("输入关键词检索所有归档内容")
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
            Text("支持 memo 正文、位置名、日期")
                .monoLabelStyle(size: 10)
                .foregroundColor(DSColor.outline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(DSColor.outlineVariant)
            Text("未找到「\(keyword)」的匹配结果")
                .bodySMStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                HStack {
                    Text("\(results.count) 条结果")
                        .monoLabelStyle(size: 10)
                        .foregroundColor(DSColor.onSurfaceVariant)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                ForEach(results) { result in
                    resultRow(result)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func resultRow(_ result: SearchResult) -> some View {
        Button(action: { onSelect(result.dateString) }) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(DSColor.primary)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(formatDate(result.dateString))
                            .font(.custom("SpaceGrotesk-Bold", size: 14))
                            .foregroundColor(DSColor.onSurface)
                        Spacer()
                        StatusBadge(
                            label: result.isDailyPageCompiled ? "VERIFIED" : "METADATA",
                            style: result.isDailyPageCompiled ? .verified : .metadata
                        )
                    }

                    Text(result.snippet)
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Image(systemName: matchIcon(for: result.matchKind))
                            .font(.system(size: 10))
                            .foregroundColor(DSColor.onSurfaceVariant)
                        Text(matchLabel(for: result.matchKind))
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DSColor.surfaceContainer)
            }
            .cornerRadius(0)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search execution

    private func scheduleSearch() {
        searchTask?.cancel()
        let current = keyword
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let hits = SearchService.search(keyword: current)
            if Task.isCancelled { return }
            await MainActor.run {
                self.results = hits
                self.hasSearched = !current.trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
    }

    // MARK: - Formatting helpers

    private func formatDate(_ dateString: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dateString) else { return dateString }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date).uppercased()
    }

    private func matchIcon(for kind: SearchResult.MatchKind) -> String {
        switch kind {
        case .memoBody: return "doc.text"
        case .location: return "mappin"
        case .date:     return "calendar"
        }
    }

    private func matchLabel(for kind: SearchResult.MatchKind) -> String {
        switch kind {
        case .memoBody: return "MEMO"
        case .location: return "LOCATION"
        case .date:     return "DATE"
        }
    }
}
