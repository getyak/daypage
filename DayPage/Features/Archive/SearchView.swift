import SwiftUI
import Combine

// MARK: - EntityFrequency

struct EntityFrequency: Hashable {
    let name: String
    let count: Int
}

// MARK: - SearchViewModel

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [SearchResult] = []
    @Published var hasSearched: Bool = false

    // MARK: Recent searches — persisted via UserDefaults
    private let recentKey = "search.recentQueries"
    private let maxRecent = 10

    var recentSearches: [String] {
        get { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }
        set {
            var trimmed = newValue.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if trimmed.count > maxRecent { trimmed = Array(trimmed.prefix(maxRecent)) }
            UserDefaults.standard.set(trimmed, forKey: recentKey)
        }
    }

    // MARK: Frequent entities — cached, loaded off the main thread

    @Published private(set) var topEntities: [EntityFrequency] = []

    // Cache key: (file count, newest mtime since reference date)
    private var entitiesCacheKey: (Int, TimeInterval)? = nil
    private var entitiesCache: [EntityFrequency] = []

    func loadTopEntities(limit: Int = 5) {
        let currentKey = entitiesCacheKey
        let currentCache = entitiesCache
        Task.detached(priority: .utility) {
            let (key, entities) = Self.scanTopEntities(
                limit: limit,
                cachedKey: currentKey,
                cachedResult: currentCache
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.entitiesCacheKey = key
                self.entitiesCache = entities
                self.topEntities = entities
            }
        }
    }

    private nonisolated static func scanTopEntities(
        limit: Int,
        cachedKey: (Int, TimeInterval)?,
        cachedResult: [EntityFrequency]
    ) -> ((Int, TimeInterval), [EntityFrequency]) {
        let rawDir = VaultInitializer.vaultURL.appendingPathComponent("raw")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: rawDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ((0, 0), []) }
        let mdFiles = files.filter { $0.pathExtension == "md" }

        // Build cache key from file count + newest mtime
        let newestMtime: TimeInterval = mdFiles.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSinceReferenceDate
        }.max() ?? 0
        let cacheKey = (mdFiles.count, newestMtime)

        if let cached = cachedKey, cached == cacheKey {
            return (cacheKey, cachedResult)
        }

        var freq: [String: Int] = [:]
        let pattern = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#)
        for url in mdFiles {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let ns = content as NSString
            let matches = pattern?.matches(in: content, range: NSRange(location: 0, length: ns.length)) ?? []
            for match in matches {
                if let r = Range(match.range(at: 1), in: content) {
                    let entity = String(content[r]).trimmingCharacters(in: .whitespaces)
                    if !entity.isEmpty { freq[entity, default: 0] += 1 }
                }
            }
        }
        let result = freq.sorted { $0.value > $1.value }.prefix(limit).map { EntityFrequency(name: $0.key, count: $0.value) }
        return (cacheKey, result)
    }

    // MARK: Save a query to recent history (dedup + prepend)
    func recordSearch(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var list = recentSearches.filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        recentSearches = list
    }

    func removeRecentSearch(_ q: String) {
        recentSearches = recentSearches.filter { $0 != q }
        objectWillChange.send()
    }

    func clearRecentSearches() {
        recentSearches = []
        objectWillChange.send()
    }

    // MARK: Result grouping

    enum Section: Equatable {
        case today
        case thisWeek
        case thisMonth
        case earlier

        var title: String {
            switch self {
            case .today:     return "今天"
            case .thisWeek:  return "本周"
            case .thisMonth: return "本月"
            case .earlier:   return "更早"
            }
        }
    }

    struct GroupedResults {
        let section: Section
        let results: [SearchResult]
    }

    func groupedResults() -> [GroupedResults] {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? todayStart
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? todayStart

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        var groups: [Section: [SearchResult]] = [:]
        for r in results {
            guard let date = fmt.date(from: r.dateString) else {
                groups[.earlier, default: []].append(r)
                continue
            }
            let section: Section
            if date >= todayStart {
                section = .today
            } else if date >= weekStart {
                section = .thisWeek
            } else if date >= monthStart {
                section = .thisMonth
            } else {
                section = .earlier
            }
            groups[section, default: []].append(r)
        }

        let order: [Section] = [.today, .thisWeek, .thisMonth, .earlier]
        return order.compactMap { s in
            guard let items = groups[s], !items.isEmpty else { return nil }
            return GroupedResults(section: s, results: items)
        }
    }
}

// MARK: - SearchView

struct SearchView: View {

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputFocused: Bool

    @StateObject private var vm = SearchViewModel()

    @State private var filters: SearchFilters = SearchFilters.empty
    @State private var showFilters: Bool = false
    @State private var cancellable: AnyCancellable? = nil
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var appearedIDs: Set<UUID> = []
    @State private var didBuzzEmpty: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .animation(.easeInOut(duration: 0.2), value: vm.hasSearched)
                        .animation(.easeInOut(duration: 0.2), value: vm.results.isEmpty)
                }
            }
            .navigationBarHidden(true)
            .animation(.easeInOut(duration: 0.2), value: showFilters)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
                setupDebounce()
                vm.loadTopEntities()
            }
            .onDisappear {
                cancellable?.cancel()
                searchTask?.cancel()
            }
        }
    }

    // MARK: - Setup Combine debounce

    private func setupDebounce() {
        cancellable = vm.$query
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [self] q in
                Task { @MainActor in
                    runSearch(keyword: q)
                }
            }
    }

    private func runSearch(keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedFilters = filters
        let wasEmpty = vm.results.isEmpty
        searchTask?.cancel()
        searchTask = Task {
            let hits = await Task.detached(priority: .userInitiated) {
                SearchService.search(keyword: trimmed, filters: capturedFilters)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                appearedIDs = []
                didBuzzEmpty = false
                vm.results = hits
                vm.hasSearched = !trimmed.isEmpty || capturedFilters.isActive
                if wasEmpty && !hits.isEmpty && !trimmed.isEmpty { Haptics.soft() }
                if hits.isEmpty { didBuzzEmpty = false }
                if UIAccessibility.isVoiceOverRunning && vm.hasSearched {
                    let message = hits.isEmpty ? "无匹配结果" : "\(hits.count) 条结果"
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
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

                TextField("搜索 memo、地点或日期", text: $vm.query)
                    .font(.custom("Inter-Regular", size: 14))
                    .foregroundColor(DSColor.onSurface)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($isInputFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        vm.recordSearch(vm.query)
                    }
                    .accessibilityLabel("搜索框")

                if !vm.query.isEmpty {
                    Button(action: {
                        vm.query = ""
                        vm.results = []
                        vm.hasSearched = false
                        isInputFocused = true
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索内容")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(DSColor.surfaceContainer)
            .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))

            Button(action: {
                Haptics.soft()
                isInputFocused = false
                showFilters.toggle()
            }) {
                Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 20))
                    .foregroundColor(filters.isActive ? DSColor.primary : DSColor.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("筛选")
            .accessibilityHint("按日期、类型、地点筛选结果")
            .accessibilityValue(filters.isActive ? "已启用" : "未启用")

            Button(action: { dismiss() }) {
                Text("取消")
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消搜索")
        }
    }

    // MARK: - Filter Panel

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        runSearch(keyword: vm.query)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
            }

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
                        .onChange(of: filters.locationQuery) { _ in runSearch(keyword: vm.query) }

                    if !filters.locationQuery.isEmpty {
                        Button(action: {
                            filters.locationQuery = ""
                            runSearch(keyword: vm.query)
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

            if filters.isActive {
                HStack {
                    Spacer()
                    Button(action: {
                        Haptics.light()
                        filters = .empty
                        runSearch(keyword: vm.query)
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
            Haptics.soft()
            if isSelected {
                filters.types.remove(type)
            } else {
                filters.types.insert(type)
            }
            runSearch(keyword: vm.query)
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
        if !vm.hasSearched {
            emptyQueryState
        } else if vm.results.isEmpty {
            emptyResultState
        } else {
            groupedResultList
        }
    }

    // MARK: - Empty-query state (recent searches + frequent entities)

    private var emptyQueryState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let recent = vm.recentSearches
                let entities = vm.topEntities

                if !recent.isEmpty {
                    sectionHeader(title: "最近搜索", trailing: AnyView(
                        Button(action: {
                            Haptics.light()
                            vm.clearRecentSearches()
                        }) {
                            Text("清除")
                                .monoLabelStyle(size: 10)
                                .foregroundColor(DSColor.primary)
                        }
                        .buttonStyle(.plain)
                    ))

                    ForEach(recent, id: \.self) { q in
                        recentSearchRow(q)
                    }
                }

                if !entities.isEmpty {
                    sectionHeader(title: "高频实体", trailing: AnyView(EmptyView()))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(entities, id: \.self) { entity in
                                entityChipWithCount(entity)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                }

                if recent.isEmpty && entities.isEmpty {
                    VStack(spacing: 20) {
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

                        VStack(alignment: .leading, spacing: 10) {
                            Text("试试搜索")
                                .monoLabelStyle(size: 10)
                                .foregroundColor(DSColor.onSurfaceVariant)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(SearchView.starterSuggestions, id: \.self) { suggestion in
                                        entityChip(suggestion)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func sectionHeader(title: String, trailing: AnyView) -> some View {
        HStack {
            Text(title)
                .monoLabelStyle(size: 10)
                .foregroundColor(DSColor.onSurfaceVariant)
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func recentSearchRow(_ q: String) -> some View {
        SwipeableRecentRow(query: q, onSelect: { query in
            Haptics.tapConfirm()
            vm.query = query
            runSearch(keyword: query)
        }, onDelete: {
            vm.removeRecentSearch(q)
        })
        Divider()
            .padding(.leading, 52)
            .background(DSColor.outlineVariant.opacity(0.5))
    }

    private func entityChip(_ entity: String) -> some View {
        Button(action: {
            Haptics.tapConfirm()
            vm.query = entity
            runSearch(keyword: entity)
        }) {
            Text(entity)
                .font(.custom("Inter-Regular", size: 13))
                .foregroundColor(DSColor.onSurface)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DSColor.surfaceContainer)
                .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func entityChipWithCount(_ entity: EntityFrequency) -> some View {
        Button(action: {
            Haptics.tapConfirm()
            vm.query = entity.name
            runSearch(keyword: entity.name)
        }) {
            HStack(spacing: 6) {
                Text(entity.name)
                    .font(.custom("Inter-Regular", size: 13))
                    .foregroundColor(DSColor.onSurface)

                Text("\(entity.count)")
                    .font(.custom("JetBrainsMono-Regular", size: 10))
                    .foregroundColor(DSColor.onSurfaceVariant)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(DSColor.outlineVariant.opacity(0.4))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DSColor.surfaceContainer)
            .overlay(Rectangle().stroke(DSColor.outlineVariant, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entity.name), \(entity.count) references")
    }

    // MARK: - Empty result state

    private var emptyResultState: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundColor(DSColor.outlineVariant)
                    if vm.query.isEmpty && filters.isActive {
                        Text("当前筛选条件下无匹配结果")
                            .bodySMStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else if !vm.query.isEmpty && filters.isActive {
                        Text("「\(vm.query)」在当前筛选条件下无匹配结果")
                            .bodySMStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else {
                        Text("未找到「\(vm.query)」的匹配结果")
                            .bodySMStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                }

                if filters.isActive {
                    Button(action: {
                        Haptics.light()
                        filters = .empty
                        runSearch(keyword: vm.query)
                    }) {
                        Text("清除筛选条件")
                            .monoLabelStyle(size: 11)
                            .foregroundColor(DSColor.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().stroke(DSColor.primary, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                } else if !vm.query.isEmpty {
                    Button(action: {
                        Haptics.light()
                        cancellable?.cancel()
                        vm.query = ""
                        vm.results = []
                        vm.hasSearched = false
                        didBuzzEmpty = false
                        setupDebounce()
                    }) {
                        Text("清除搜索")
                            .monoLabelStyle(size: 11)
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().stroke(DSColor.outlineVariant, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                let recentSuggestions = Array(vm.recentSearches.filter { $0 != vm.query }.prefix(4))
                if !recentSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("换个关键词试试")
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recentSuggestions, id: \.self) { q in
                                    entityChip(q)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .scaleEffect(didBuzzEmpty ? 1.0 : (reduceMotion ? 1.0 : 0.88))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: didBuzzEmpty)
        .transition(.opacity)
        .dsAnimation(Motion.fade, value: vm.results.isEmpty)
        .onAppear {
            if !didBuzzEmpty {
                didBuzzEmpty = true
                if !reduceMotion { Haptics.warn() }
            }
        }
    }

    // MARK: - Grouped result list

    private var groupedResultList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                let groups = vm.groupedResults()
                let total = vm.results.count

                // Total count header
                HStack {
                    Text("\(total) 条结果")
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
                .padding(.bottom, 8)

                ForEach(groups, id: \.section) { group in
                    Section {
                        ForEach(group.results) { result in
                            let appeared = appearedIDs.contains(result.id)
                            resultRow(result)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared || reduceMotion ? 0 : 10)
                                .onAppear {
                                    guard !appearedIDs.contains(result.id) else { return }
                                    withAnimation(reduceMotion ? .linear(duration: 0.001) : Motion.rise) {
                                        appearedIDs.insert(result.id)
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text(group.section.title)
                                .monoLabelStyle(size: 10)
                                .foregroundColor(DSColor.onSurfaceVariant)
                            Rectangle()
                                .fill(DSColor.outlineVariant)
                                .frame(height: 1)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(DSColor.background)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func resultRow(_ result: SearchResult) -> some View {
        let status = result.isDailyPageCompiled ? "VERIFIED" : "METADATA"
        let snippet = String(result.snippet.prefix(80))
        let a11yLabel = "\(formatDate(result.dateString)), \(matchLabel(for: result.matchKind)) match, \(status), \(snippet)"
        return Button(action: {
            Haptics.tapConfirm()
            vm.recordSearch(vm.query)
            onSelect(result.dateString)
        }) {
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

                    highlightedSnippet(result.snippet, keyword: vm.query)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

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
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityHint("双击打开当天页面")
    }

    // MARK: - Keyword highlight via AttributedString

    @ViewBuilder
    private func highlightedSnippet(_ snippet: String, keyword: String) -> some View {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Text(snippet)
                .bodySMStyle()
                .foregroundColor(DSColor.onSurface)
        } else {
            Text(buildHighlightedString(snippet, keyword: trimmed))
                .bodySMStyle()
        }
    }

    private func buildHighlightedString(_ text: String, keyword: String) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = UIColor(DSColor.onSurface)

        let loweredText = text.lowercased()
        let loweredKeyword = keyword.lowercased()

        var searchStart = loweredText.startIndex
        while searchStart < loweredText.endIndex,
              let range = loweredText.range(of: loweredKeyword, range: searchStart..<loweredText.endIndex) {
            // Map the range from lowercased string to the original text
            let offset = loweredText.distance(from: loweredText.startIndex, to: range.lowerBound)
            let length = loweredText.distance(from: range.lowerBound, to: range.upperBound)

            let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let attrEnd = attributed.index(attrStart, offsetByCharacters: length)
            let attrRange = attrStart..<attrEnd

            attributed[attrRange].backgroundColor = UIColor(DSColor.amberAccent).withAlphaComponent(0.28)
            attributed[attrRange].foregroundColor = UIColor(DSColor.onSurface)
            attributed[attrRange].font = .system(size: 13, weight: .semibold)

            searchStart = range.upperBound
        }

        return attributed
    }

    // MARK: - Starter suggestions (shown only when no history and no indexed entities)

    private static let starterSuggestions: [String] = ["今天", "本周", "本月", "位置", "照片", "语音"]

    // MARK: - Formatting helpers

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func formatDate(_ dateString: String) -> String {
        guard let date = SearchView.dateParser.date(from: dateString) else { return dateString }
        return SearchView.dateFormatter.string(from: date).uppercased()
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

// MARK: - SwipeableRecentRow

private struct SwipeableRecentRow: View {

    let query: String
    let onSelect: (String) -> Void
    let onDelete: () -> Void

    private let revealWidth: CGFloat = 64
    private let snapThreshold: CGFloat = 32

    @State private var revealed: Bool = false
    @GestureState private var drag: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentOffset: CGFloat {
        let base: CGFloat = revealed ? -revealWidth : 0
        let live = min(0, drag)
        let combined = base + live
        if combined < -revealWidth {
            return -revealWidth + (combined + revealWidth) * 0.25
        }
        return combined
    }

    private var snapAnimation: Animation {
        reduceMotion ? .linear(duration: 0.001) : Motion.spring
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete action surface — revealed on left swipe
            Button(action: {
                withAnimation(snapAnimation) { revealed = false }
                Haptics.warn()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onDelete() }
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                    .background(DSColor.error)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除该搜索记录")

            // Row content
            HStack {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundColor(DSColor.outline)

                Button(action: {
                    if revealed {
                        withAnimation(snapAnimation) { revealed = false }
                    } else {
                        onSelect(query)
                    }
                }) {
                    Text(query)
                        .font(.custom("Inter-Regular", size: 14))
                        .foregroundColor(DSColor.onSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button(action: { onDelete() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(DSColor.outline)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除该搜索记录")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(DSColor.background)
            .offset(x: currentOffset)
            .highPriorityGesture(
                DragGesture(minimumDistance: 10)
                    .updating($drag) { value, state, _ in
                        let tx = value.translation.width
                        if tx < 0 { state = tx }
                    }
                    .onEnded { value in
                        let tx = value.translation.width
                        if revealed {
                            withAnimation(snapAnimation) {
                                revealed = (tx > -snapThreshold)
                            }
                        } else {
                            withAnimation(snapAnimation) {
                                revealed = (tx < -snapThreshold)
                            }
                        }
                    }
            )
        }
        .clipped()
    }
}

// MARK: - SearchViewModel.GroupedResults: Identifiable

extension SearchViewModel.GroupedResults: Identifiable {
    var id: SearchViewModel.Section { section }
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
