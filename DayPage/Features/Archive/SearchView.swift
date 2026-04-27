import SwiftUI

// MARK: - SearchView

/// 从 ``ArchiveView`` 呈现的全屏搜索面板。
/// 运行内存中的 ``SearchService`` 查询，带 150 毫秒防抖，
/// 并将选中的日期传回父视图以打开 Daily Page。
struct SearchView: View {

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputFocused: Bool

    @State private var keyword: String = ""
    @State private var results: [SearchResult] = []
    @State private var hasSearched: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil

    @State private var filters: SearchFilters = SearchFilters.empty
    @State private var showFilters: Bool = false

    /// 当用户点击某条命中时，以 "yyyy-MM-dd" 格式调用。
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

                    if showFilters {
                        filterPanel
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        Divider().background(DSColor.outlineVariant)
                    }

                    contentArea
                }
            }
            .navigationBarHidden(true)
            .animation(.easeInOut(duration: 0.2), value: showFilters)
            .onAppear {
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

            // Filter toggle button
            Button(action: {
                isInputFocused = false
                showFilters.toggle()
            }) {
                Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 20))
                    .foregroundColor(filters.isActive ? DSColor.primary : DSColor.onSurfaceVariant)
            }
            .buttonStyle(.plain)

            Button(action: { dismiss() }) {
                Text("取消")
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.primary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Filter Panel

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Date range row
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .frame(width: 16)

                Text("日期范围")
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .frame(width: 48, alignment: .leading)

                Spacer()

                DatePicker("", selection: Binding(
                    get: { filters.startDate ?? Date.distantPast },
                    set: { filters.startDate = $0 == Date.distantPast ? nil : $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .font(.custom("Inter-Regular", size: 12))
                .frame(maxWidth: 120)
                .overlay(
                    filters.startDate == nil
                        ? Text("开始日期").monoLabelStyle(size: 11).foregroundColor(DSColor.onSurfaceVariant).allowsHitTesting(false)
                        : nil
                )

                Text("—")
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.outline)

                DatePicker("", selection: Binding(
                    get: { filters.endDate ?? Date() },
                    set: { filters.endDate = $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .font(.custom("Inter-Regular", size: 12))
                .frame(maxWidth: 120)

                if filters.startDate != nil || filters.endDate != nil {
                    Button(action: {
                        filters.startDate = nil
                        filters.endDate = nil
                        scheduleSearch()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Type multi-select row
            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .font(.system(size: 12))
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .frame(width: 16)

                Text("类型")
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .frame(width: 48, alignment: .leading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Memo.MemoType.filterOptions, id: \.self) { type in
                            typeChip(type)
                        }
                    }
                }
            }

            // Location filter row
            HStack(spacing: 8) {
                Image(systemName: "mappin")
                    .font(.system(size: 12))
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .frame(width: 16)

                Text("地点")
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .frame(width: 48, alignment: .leading)

                HStack(spacing: 6) {
                    TextField("过滤地点名称", text: $filters.locationQuery)
                        .font(.custom("Inter-Regular", size: 13))
                        .foregroundColor(DSColor.onSurface)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onChange(of: filters.locationQuery) { _ in scheduleSearch() }

                    if !filters.locationQuery.isEmpty {
                        Button(action: {
                            filters.locationQuery = ""
                            scheduleSearch()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(DSColor.onSurfaceVariant)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(DSColor.surfaceContainer)
                .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
            }

            // Clear all filters
            if filters.isActive {
                HStack {
                    Spacer()
                    Button(action: {
                        filters = .empty
                        scheduleSearch()
                    }) {
                        Text("清除全部筛选")
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DSColor.surfaceContainer.opacity(0.5))
    }

    private func typeChip(_ type: Memo.MemoType) -> some View {
        let isSelected = filters.types.contains(type)
        return Button(action: {
            if isSelected {
                filters.types.remove(type)
            } else {
                filters.types.insert(type)
            }
            scheduleSearch()
        }) {
            HStack(spacing: 4) {
                Image(systemName: type.iconName)
                    .font(.system(size: 10))
                Text(type.displayName)
                    .monoLabelStyle(size: 10)
            }
            .foregroundColor(isSelected ? DSColor.onPrimary : DSColor.onSurfaceVariant)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? DSColor.primary : DSColor.surfaceContainer)
            .overlay(
                Rectangle()
                    .stroke(isSelected ? DSColor.primary : DSColor.outlineVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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

            if filters.isActive {
                Text("已启用筛选条件，点击搜索框输入关键词")
                    .monoLabelStyle(size: 10)
                    .foregroundColor(DSColor.primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(DSColor.outlineVariant)
            if keyword.isEmpty && filters.isActive {
                Text("当前筛选条件下无匹配结果")
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                Text("未找到「\(keyword)」的匹配结果")
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
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
                    if filters.isActive {
                        Label("已筛选", systemImage: "line.3.horizontal.decrease.circle.fill")
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.primary)
                    }
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

                        if let type = result.memoType {
                            Image(systemName: type.iconName)
                                .font(.system(size: 10))
                                .foregroundColor(DSColor.onSurfaceVariant)
                            Text(type.displayName.uppercased())
                                .monoLabelStyle(size: 10)
                                .foregroundColor(DSColor.onSurfaceVariant)
                        }
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
        let currentKeyword = keyword
        let currentFilters = filters
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let hits = SearchService.search(keyword: currentKeyword, filters: currentFilters)
            if Task.isCancelled { return }
            await MainActor.run {
                self.results = hits
                let active = !currentKeyword.trimmingCharacters(in: .whitespaces).isEmpty || currentFilters.isActive
                self.hasSearched = active
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

// MARK: - Memo.MemoType + UI helpers

private extension Memo.MemoType {
    static let filterOptions: [Memo.MemoType] = [.text, .voice, .photo, .location]

    var displayName: String {
        switch self {
        case .text:     return "文字"
        case .voice:    return "语音"
        case .photo:    return "照片"
        case .location: return "位置"
        case .mixed:    return "混合"
        }
    }

    var iconName: String {
        switch self {
        case .text:     return "doc.text"
        case .voice:    return "waveform"
        case .photo:    return "photo"
        case .location: return "mappin"
        case .mixed:    return "square.grid.2x2"
        }
    }
}
