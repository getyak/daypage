import SwiftUI
import Combine
import DayPageModels
import DayPageStorage
import DayPageServices

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
    @Published var isSearching: Bool = false

    // MARK: Recent searches — persisted via UserDefaults
    private let recentKey = "search.recentQueries"
    private let maxRecent = 10

    @Published var lastClearedSearches: [String]? = nil
    private var clearUndoTask: Task<Void, Never>? = nil

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
    @Published private(set) var isLoadingEntities: Bool = false

    // Cache key: (file count, newest mtime since reference date)
    private var entitiesCacheKey: (Int, TimeInterval)? = nil
    private var entitiesCache: [EntityFrequency] = []

    func loadTopEntities(limit: Int = 5) {
        isLoadingEntities = true
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
                self.isLoadingEntities = false
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
        let current = recentSearches
        guard !current.isEmpty else { return }
        lastClearedSearches = current
        recentSearches = []
        objectWillChange.send()
        clearUndoTask?.cancel()
        clearUndoTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, lastClearedSearches != nil else { return }
            lastClearedSearches = nil
        }
    }

    func undoClearRecentSearches() {
        guard let snapshot = lastClearedSearches else { return }
        clearUndoTask?.cancel()
        clearUndoTask = nil
        recentSearches = snapshot
        lastClearedSearches = nil
        objectWillChange.send()
    }

    func cancelClearUndo() {
        clearUndoTask?.cancel()
        clearUndoTask = nil
    }

    // MARK: Result grouping — with optional kind filter

    func groupedResults(from source: [SearchResult]) -> [GroupedResults] {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? todayStart
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? todayStart

        let fmt = DateFormatters.isoDate

        var groups: [Section: [SearchResult]] = [:]
        for r in source {
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

    enum Section: Equatable {
        case today
        case thisWeek
        case thisMonth
        case earlier

        var title: String {
            switch self {
            case .today:     return NSLocalizedString("search.section.today", comment: "Search section header: today")
            case .thisWeek:  return NSLocalizedString("search.section.thisWeek", comment: "Search section header: this week")
            case .thisMonth: return NSLocalizedString("search.section.thisMonth", comment: "Search section header: this month")
            case .earlier:   return NSLocalizedString("search.section.earlier", comment: "Search section header: earlier")
            }
        }
    }

    struct GroupedResults {
        let section: Section
        let results: [SearchResult]
    }

    func groupedResults() -> [GroupedResults] {
        groupedResults(from: results)
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
    @State private var activeMatchKinds: Set<SearchResult.MatchKind> = []
    @State private var appearedRecents: Set<String> = []
    @State private var didBuzzEmpty: Bool = false
    @State private var lastBuzzedEmptyQuery: String? = nil
    @State private var clearPressed: Bool = false
    @State private var searchScrollProxy: ScrollViewProxy? = nil
    @State private var lastScrolledQuery: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onSelect: (String) -> Void

    /// Optional pre-filled query string set when SearchView is presented from
    /// a deep link (e.g. `AskTodayIntent` → `daypage://search?q=…`). Applied
    /// once in `.onAppear`; further user input flows through `vm.query` as
    /// usual.
    var initialQuery: String? = nil

    private var visibleResults: [SearchResult] {
        activeMatchKinds.isEmpty ? vm.results : vm.results.filter { activeMatchKinds.contains($0.matchKind) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // W1: the flat background made the sheet read like a cold
                // sheet of printer paper against the warm archive behind it —
                // search breathes the same ambient air as every other page.
                AmbientBackground().ignoresSafeArea()

                VStack(spacing: 0) {
                    // The capsule floats on the ambient ground — no hard
                    // divider slicing the sheet in two.
                    searchBar
                        .padding(.horizontal, DSSpacing.lg)
                        .padding(.vertical, DSSpacing.md)

                    if showFilters {
                        filterPanel
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        Rectangle()
                            .fill(DSColor.inkFaint)
                            .frame(height: 0.5)
                    }

                    contentArea
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: vm.hasSearched)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: vm.results.isEmpty)
                }
                .overlay(alignment: .bottom) {
                    if vm.lastClearedSearches != nil {
                        UndoPillView(
                            label: NSLocalizedString("search.undo.cleared", comment: "Undo clear recent searches pill label")
                        ) {
                            Haptics.soft()
                            vm.undoClearRecentSearches()
                        } onDismiss: {
                            vm.cancelClearUndo()
                            vm.lastClearedSearches = nil
                        }
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : Motion.rise, value: vm.lastClearedSearches != nil)
            }
            .navigationBarHidden(true)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showFilters)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
                setupDebounce()
                vm.loadTopEntities()
                // Belt-and-braces (#827): the app-launch warmUp normally has
                // the index ready long before Search opens; this covers cold
                // deep-link entries. No-op once built.
                SearchIndex.shared.warmUp()
                // Pre-populate query when SearchView was opened from a deep
                // link (e.g. `daypage://search?q=…`). Only runs on first
                // appear; setupDebounce → Combine pipeline will execute the
                // search via the debounced subscription.
                if let initial = initialQuery, !initial.isEmpty {
                    if vm.query.isEmpty { vm.query = initial }
                    // Issue #18 (2026-07-03): deep-link seeded queries
                    // never hit onSubmit; mirror the analytics event
                    // here so the debug board shows a search funnel that
                    // includes shortcut/URL entries.
                    AnalyticsService.shared.record(
                        AnalyticsService.Name.searchUsed,
                        props: ["query_len": String(initial.count), "source": "deeplink"]
                    )
                }
            }
            .onChange(of: initialQuery) { newValue in
                // Issue #18 (2026-07-03) — cover the case where the
                // sheet is already presented (SwiftUI won't re-fire
                // onAppear then). A fresh deep-link push updates
                // initialQuery in place; we re-record here so the
                // analytics stream stays authoritative regardless of
                // sheet lifecycle.
                guard let q = newValue, !q.isEmpty else { return }
                vm.query = q
                AnalyticsService.shared.record(
                    AnalyticsService.Name.searchUsed,
                    props: ["query_len": String(q.count), "source": "deeplink"]
                )
            }
            .onDisappear {
                cancellable?.cancel()
                searchTask?.cancel()
                searchScrollProxy = nil
                lastScrolledQuery = nil
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
        if !trimmed.isEmpty || capturedFilters.isActive {
            vm.isSearching = true
        }
        searchTask = Task {
            // #827: prefer the pre-folded in-memory SearchIndex (a keystroke
            // costs an in-memory scan, zero disk I/O). Falls back to the
            // legacy full-vault disk scan only while the index's first
            // background build is still in flight.
            let docs = await MainActor.run { SearchIndex.shared.documentsIfBuilt() }
            let hits = await Task.detached(priority: .userInitiated) {
                if let docs {
                    return SearchService.search(keyword: trimmed, filters: capturedFilters, in: docs)
                }
                return SearchService.search(keyword: trimmed, filters: capturedFilters)
            }.value
            guard !Task.isCancelled else {
                await MainActor.run { vm.isSearching = false }
                return
            }
            await MainActor.run {
                vm.isSearching = false
                appearedIDs = []
                activeMatchKinds = []
                let willBeEmpty = trimmed.isEmpty && !capturedFilters.isActive
                if willBeEmpty { appearedRecents = [] }
                vm.results = hits
                vm.hasSearched = !trimmed.isEmpty || capturedFilters.isActive
                if hits.isEmpty && vm.hasSearched {
                    if trimmed != lastBuzzedEmptyQuery {
                        if !reduceMotion { Haptics.warn() }
                        lastBuzzedEmptyQuery = trimmed
                        didBuzzEmpty = false
                    }
                } else if !hits.isEmpty {
                    lastBuzzedEmptyQuery = nil
                    didBuzzEmpty = false
                }
                if wasEmpty && !hits.isEmpty && !trimmed.isEmpty { Haptics.soft() }
                // Scroll to top when a different query yields results
                let scrollKey = trimmed + (capturedFilters.isActive ? "|filtered" : "")
                if !hits.isEmpty && scrollKey != lastScrolledQuery {
                    lastScrolledQuery = scrollKey
                    withAnimation(reduceMotion ? nil : Motion.spring) {
                        searchScrollProxy?.scrollTo("searchTop", anchor: .top)
                    }
                }
                if UIAccessibility.isVoiceOverRunning && vm.hasSearched {
                    let message = hits.isEmpty
                        ? NSLocalizedString("search.a11y.noResults", comment: "VoiceOver: no results found")
                        : String(format: NSLocalizedString("search.a11y.resultCount", comment: "VoiceOver: result count announcement"), hits.count)
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: DSSpacing.md) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(DSColor.inkMuted)

                TextField(NSLocalizedString("search.placeholder", comment: "Search text field placeholder"), text: $vm.query)
                    .font(DSFonts.inter(size: 15, relativeTo: .subheadline))
                    .foregroundColor(DSColor.inkPrimary)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($isInputFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        vm.recordSearch(vm.query)
                        // Issue #18: feed only the query *length* (never
                        // the query string itself — PII) into the local
                        // analytics stream so the debug board can show
                        // search-funnel volume.
                        AnalyticsService.shared.record(
                            AnalyticsService.Name.searchUsed,
                            props: ["query_len": String(vm.query.count)]
                        )
                    }
                    .accessibilityLabel(NSLocalizedString("search.a11y.searchField", comment: "Accessibility label for the search text field"))

                if vm.isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(DSColor.inkMuted)
                        .accessibilityLabel(NSLocalizedString("search.a11y.searching", comment: "Accessibility label for the searching progress indicator"))
                } else if !vm.query.isEmpty {
                    Button(action: {
                        Haptics.soft()
                        if !reduceMotion {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                                clearPressed = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                                    clearPressed = false
                                }
                            }
                        }
                        vm.query = ""
                        vm.results = []
                        vm.hasSearched = false
                        appearedRecents = []
                        activeMatchKinds = []
                        lastScrolledQuery = nil
                        isInputFocused = true
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(DSColor.inkMuted)
                            .scaleEffect(clearPressed ? 0.8 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("search.a11y.clearSearch", comment: "Accessibility label for the clear search button"))
                }
            }
            // W1: 36pt hard-stroked box → 44pt capsule on the glass engine,
            // same family as the archive header's search control.
            .padding(.horizontal, DSSpacing.lg)
            .frame(height: 44)
            .dpGlass(.control, in: Capsule())
            .clipShape(Capsule())

            Button(action: {
                Haptics.soft()
                isInputFocused = false
                showFilters.toggle()
            }) {
                Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 20))
                    .foregroundColor(filters.isActive ? DSColor.accentOnBg : DSColor.inkMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("search.a11y.filter", comment: "Accessibility label for the filter button"))
            .accessibilityHint(NSLocalizedString("search.a11y.filter.hint", comment: "Accessibility hint for the filter button"))
            .accessibilityValue(filters.isActive ? NSLocalizedString("search.a11y.filter.enabled", comment: "Filter active state") : NSLocalizedString("search.a11y.filter.disabled", comment: "Filter inactive state"))

            Button(action: { dismiss() }) {
                Text(NSLocalizedString("search.cancel", comment: "Cancel button in search bar"))
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.accentOnBg)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("search.a11y.cancelSearch", comment: "Accessibility label for the cancel search button"))
        }
    }

    // MARK: - Filter Panel

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 16)

                Text(NSLocalizedString("search.filter.dateRange", comment: "Filter panel label: date range"))
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 48, alignment: .leading)

                Spacer()

                DatePicker("", selection: Binding(
                    get: { filters.startDate ?? Date.distantPast },
                    set: { filters.startDate = $0 == Date.distantPast ? nil : $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .font(DSFonts.inter(size: 12, relativeTo: .caption))
                .frame(maxWidth: 120)
                .overlay(
                    filters.startDate == nil
                        ? Text(NSLocalizedString("search.filter.startDate", comment: "Filter panel start date placeholder")).monoLabelStyle(size: 11).foregroundColor(DSColor.inkMuted).allowsHitTesting(false)
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
                .font(DSFonts.inter(size: 12, relativeTo: .caption))
                .frame(maxWidth: 120)

                if filters.startDate != nil || filters.endDate != nil {
                    Button(action: {
                        filters.startDate = nil
                        filters.endDate = nil
                        runSearch(keyword: vm.query)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(DSColor.inkMuted)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "tag")
                    .font(.system(size: 12))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 16)

                Text(NSLocalizedString("search.filter.type", comment: "Filter panel label: memo type"))
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 48, alignment: .leading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Memo.MemoType.filterOptions, id: \.self) { type in
                            typeChip(type)
                        }
                    }
                }
            }

            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "mappin")
                    .font(.system(size: 12))
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 16)

                Text(NSLocalizedString("search.filter.location", comment: "Filter panel label: location"))
                    .monoLabelStyle(size: 11)
                    .foregroundColor(DSColor.inkMuted)
                    .frame(width: 48, alignment: .leading)

                HStack(spacing: 6) {
                    TextField(NSLocalizedString("search.filter.location.placeholder", comment: "Filter panel location text field placeholder"), text: $filters.locationQuery)
                        .font(DSFonts.inter(size: 13, relativeTo: .footnote))
                        .foregroundColor(DSColor.inkPrimary)
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
                                .foregroundColor(DSColor.inkMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .dpGlass(.pill, in: Capsule())
                .clipShape(Capsule())
            }

            if filters.isActive {
                HStack {
                    Spacer()
                    Button(action: {
                        Haptics.light()
                        filters = .empty
                        runSearch(keyword: vm.query)
                    }) {
                        Text(NSLocalizedString("search.filter.clearAll", comment: "Clear all filters button"))
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.accentOnBg)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
        .background(DSColor.surfaceWhite.opacity(0.35))
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
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: type.iconName)
                    .font(.system(size: 10))
                Text(type.displayName)
                    .monoLabelStyle(size: 10)
            }
            .foregroundColor(isSelected ? DSColor.onAmber : DSColor.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? DSColor.amberDeep : DSColor.glassLo, in: Capsule())
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

    // MARK: - Vault overview (moved from ArchiveView, #827)

    /// Whole-vault sense of scale: total memos + total days. Reads the
    /// launch-warmed TimelineIndex synchronously (O(1) once built); shows
    /// em-dashes before warm-up so "loading" is distinguishable from a
    /// genuinely empty vault.
    /// One quiet mono line ("1,284 MEMOS · 342 DAYS") — the old two serif
    /// pillars gave a footnote the loudest voice on the sheet.
    private var vaultOverviewStrip: some View {
        let all = TimelineIndex.shared.entries()
        let totalMemos = all.reduce(0) { $0 + $1.memoCount }
        let totalDays = all.count
        let hasData = totalDays > 0 || totalMemos > 0
        return Text(hasData
            ? String(format: NSLocalizedString("search.overview.line", comment: "Vault overview line: %1$d memos, %2$d days"), totalMemos, totalDays)
            : "— · —")
            .font(DSType.mono10)
            .tracking(1.0)
            .foregroundColor(DSColor.inkMuted)
            .accessibilityLabel(String(
                format: NSLocalizedString("search.overview.a11y", comment: "Vault overview a11y: %d memos across %d days"),
                totalMemos, totalDays
            ))
    }

    // MARK: - Empty-query state (recent searches + frequent entities)

    private var emptyQueryState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let recent = vm.recentSearches
                let entities = vm.topEntities

                // #827: whole-vault scale moved here from ArchiveView — as a
                // search-surface prologue it answers "how much is searchable",
                // instead of shouting over Archive's month summary.
                vaultOverviewStrip
                    .padding(.horizontal, DSSpacing.xl)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                // W1: the "QUICK SEARCH" starter row is gone from the
                // populated state — it stacked a fourth equal-weight section
                // above the user's own history and mostly duplicated the
                // entity chips below. Starters still carry the true-empty
                // state further down.

                if !recent.isEmpty {
                    sectionHeader(title: NSLocalizedString("search.section.recentSearches", comment: "Recent searches section header"), trailing: AnyView(
                        Button(action: {
                            Haptics.light()
                            vm.clearRecentSearches()
                        }) {
                            Text(NSLocalizedString("search.recent.clear", comment: "Clear recent searches button"))
                                .monoLabelStyle(size: 10)
                                .foregroundColor(DSColor.accentOnBg)
                        }
                        .buttonStyle(.plain)
                    ))

                    ForEach(Array(recent.enumerated()), id: \.element) { idx, q in
                        recentSearchRow(q, index: idx)
                    }
                }

                if !entities.isEmpty || vm.isLoadingEntities {
                    sectionHeader(title: NSLocalizedString("search.section.topEntities", comment: "Top entities section header"), trailing: AnyView(EmptyView()))

                    Group {
                        if vm.isLoadingEntities && entities.isEmpty {
                            EntityChipSkeleton(reduceMotion: reduceMotion)
                                .transition(.opacity)
                        } else {
                            let maxCount = entities.map(\.count).max() ?? 1
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: DSSpacing.sm) {
                                    ForEach(Array(entities.enumerated()), id: \.element) { idx, entity in
                                        entityChipWithCount(entity, maxCount: maxCount, index: idx)
                                    }
                                }
                                .padding(.horizontal, DSSpacing.xl)
                                .padding(.vertical, 10)
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(Motion.fade, value: vm.isLoadingEntities)
                }

                if recent.isEmpty && entities.isEmpty && !vm.isLoadingEntities {
                    VStack(spacing: DSSpacing.xl) {
                        VStack(spacing: DSSpacing.md) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 32, weight: .regular))
                                .foregroundColor(DSColor.outlineVariant)
                            Text(NSLocalizedString("search.empty.prompt", comment: "Empty search state main prompt"))
                                .bodySMStyle()
                                .foregroundColor(DSColor.inkMuted)
                            Text(NSLocalizedString("search.empty.hint", comment: "Empty search state hint text"))
                                .monoLabelStyle(size: 10)
                                .foregroundColor(DSColor.outline)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text(NSLocalizedString("search.empty.trySuggestion", comment: "Try a suggestion label in empty search state"))
                                .monoLabelStyle(size: 10)
                                .foregroundColor(DSColor.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, DSSpacing.xl)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: DSSpacing.sm) {
                                    ForEach(SearchView.starterSuggestions, id: \.self) { suggestion in
                                        entityChip(suggestion)
                                    }
                                }
                                .padding(.horizontal, DSSpacing.xl)
                                .padding(.vertical, DSSpacing.xs)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
            }
            .padding(.bottom, DSSpacing.xl2)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// "1 RESULTS" fix — mono archival label, code-side singular (the label
    /// family is intentionally untranslated English; see FINDING-010).
    static func resultCountText(_ n: Int) -> String {
        String(format: NSLocalizedString(
            n == 1 ? "search.result.count.one" : "search.result.count",
            comment: "Total result count label; %d = count"
        ), n)
    }

    private func sectionHeader(title: String, trailing: AnyView) -> some View {
        HStack {
            Text(title)
                .monoLabelStyle(size: 10)
                .foregroundColor(DSColor.inkMuted)
            Spacer()
            trailing
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, 24)
        .padding(.bottom, DSSpacing.xs)
    }

    @ViewBuilder
    private func recentSearchRow(_ q: String, index: Int) -> some View {
        SwipeableRecentRow(
            query: q,
            index: index,
            appeared: appearedRecents.contains(q),
            reduceMotion: reduceMotion,
            onSelect: { query in selectSuggestion(query) },
            onDelete: { vm.removeRecentSearch(q) },
            onAppeared: { appearedRecents.insert(q) }
        )
        Divider()
            .padding(.leading, 52)
            .background(DSColor.outlineVariant.opacity(0.5))
    }

    private func selectSuggestion(_ term: String) {
        Haptics.tapConfirm()
        vm.query = term
        vm.recordSearch(term)
        runSearch(keyword: term)
    }

    private func entityChip(_ entity: String) -> some View {
        Button(action: {
            selectSuggestion(entity)
        }) {
            Text(entity)
                .font(DSFonts.inter(size: 13, relativeTo: .footnote))
                .foregroundColor(DSColor.inkPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .dpGlass(.pill, in: Capsule())
                .clipShape(Capsule())
        }
        .buttonStyle(ChipButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(String(format: NSLocalizedString("search.a11y.entityChip", comment: "Accessibility label for entity chip; %@ = entity name"), entity))
        .accessibilityHint(NSLocalizedString("search.a11y.entityChip.hint", comment: "Accessibility hint for entity chip"))
        .accessibilityAddTraits(.isButton)
    }

    private func entityChipWithCount(_ entity: EntityFrequency, maxCount: Int, index: Int) -> some View {
        let ratio = maxCount > 0 ? CGFloat(entity.count) / CGFloat(maxCount) : 0
        let isTop = entity.count == maxCount
        let pctLabel = isTop
            ? NSLocalizedString("search.entity.mostFrequent", comment: "most frequent entity label")
            : String(format: NSLocalizedString("search.entity.relativeFrequency", comment: "relative frequency label"), Int((ratio * 100).rounded()))
        let a11yLabel = "\(entity.name), \(entity.count) references, \(pctLabel)"

        return EntityFrequencyChip(
            entity: entity,
            ratio: ratio,
            index: index,
            reduceMotion: reduceMotion,
            a11yLabel: a11yLabel
        ) {
            selectSuggestion(entity.name)
        }
    }

    // MARK: - Empty result state

    private var emptyResultState: some View {
        ScrollView {
            VStack(spacing: DSSpacing.xl) {
                VStack(spacing: DSSpacing.md) {
                    Image(systemName: "tray")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundColor(DSColor.outlineVariant)
                    if vm.query.isEmpty && filters.isActive {
                        Text(NSLocalizedString("search.empty.noMatchFiltered", comment: "No results with active filters and no query"))
                            .bodySMStyle()
                            .foregroundColor(DSColor.inkMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else if !vm.query.isEmpty && filters.isActive {
                        Text(String(format: NSLocalizedString("search.empty.noMatchQueryFiltered", comment: "No results for query with active filters; %@ = query"), vm.query))
                            .bodySMStyle()
                            .foregroundColor(DSColor.inkMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else {
                        Text(String(format: NSLocalizedString("search.empty.noMatchQuery", comment: "No results for query; %@ = query"), vm.query))
                            .bodySMStyle()
                            .foregroundColor(DSColor.inkMuted)
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
                        Text(NSLocalizedString("search.empty.clearFilters", comment: "Clear filters button in empty result state"))
                            .monoLabelStyle(size: 11)
                            .foregroundColor(DSColor.accentOnBg)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().stroke(DSColor.accentOnBg, lineWidth: 1))
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
                        lastScrolledQuery = nil
                        setupDebounce()
                        isInputFocused = true
                    }) {
                        Text(NSLocalizedString("search.empty.clearSearch", comment: "Clear search button in empty result state"))
                            .monoLabelStyle(size: 11)
                            .foregroundColor(DSColor.inkMuted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().stroke(DSColor.outlineVariant, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                let recentSuggestions = Array(vm.recentSearches.filter { $0 != vm.query }.prefix(4))
                if !recentSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(NSLocalizedString("search.empty.tryAnother", comment: "Try another keyword suggestion label"))
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DSSpacing.xl)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DSSpacing.sm) {
                                ForEach(recentSuggestions, id: \.self) { q in
                                    entityChip(q)
                                }
                            }
                            .padding(.horizontal, DSSpacing.xl)
                            .padding(.vertical, DSSpacing.xs)
                        }
                    }
                }

                let entitySuggestions = vm.topEntities.prefix(6).map(\.name).filter { $0 != vm.query }
                if !entitySuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(NSLocalizedString("search.section.topEntities", comment: "Top entities section header"))
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DSSpacing.xl)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DSSpacing.sm) {
                                ForEach(entitySuggestions, id: \.self) { name in
                                    entityChip(name)
                                }
                            }
                            .padding(.horizontal, DSSpacing.xl)
                            .padding(.vertical, DSSpacing.xs)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
            .padding(.bottom, DSSpacing.xl2)
        }
        .scrollDismissesKeyboard(.interactively)
        .scaleEffect(didBuzzEmpty ? 1.0 : (reduceMotion ? 1.0 : 0.88))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: didBuzzEmpty)
        .transition(.opacity)
        .dsAnimation(Motion.fade, value: vm.results.isEmpty)
        .onAppear {
            if !didBuzzEmpty {
                didBuzzEmpty = true
            }
        }
    }

    // MARK: - Grouped result list

    private var groupedResultList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Invisible anchor for scroll-to-top; also captures the ScrollViewProxy
                Color.clear.frame(height: 0).id("searchTop")
                    .onAppear { searchScrollProxy = proxy }

                let visible = visibleResults
                let groups = vm.groupedResults(from: visible)
                let total = vm.results.count
                let visibleCount = visible.count
                let presentKinds = Set(vm.results.map(\.matchKind))

                // Total count header — tappable to scroll back to top
                Button(action: {
                    Haptics.tapConfirm()
                    withAnimation(reduceMotion ? nil : Motion.spring) {
                        proxy.scrollTo("searchTop", anchor: .top)
                    }
                }) {
                HStack {
                    Text(activeMatchKinds.isEmpty
                         ? Self.resultCountText(total)
                         : String(format: NSLocalizedString("search.result.countFiltered", comment: "Filtered result count label; first %d = visible, second %d = total"), visibleCount, total))
                        .monoLabelStyle(size: 10)
                        .foregroundColor(DSColor.inkMuted)
                        .modifier(NumericTextContentTransition(value: Double(visibleCount), reduceMotion: reduceMotion))
                        .animation(reduceMotion ? nil : Motion.spring, value: visibleCount)
                    Spacer()
                    if filters.isActive {
                        Label(NSLocalizedString("search.result.filtered", comment: "Filtered badge label"), systemImage: "line.3.horizontal.decrease.circle.fill")
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.accentOnBg)
                    }
                }
                .padding(.horizontal, DSSpacing.xl)
                .padding(.top, DSSpacing.md)
                .padding(.bottom, activeMatchKinds.isEmpty && presentKinds.count <= 1 ? 8 : 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: NSLocalizedString("search.a11y.showingResults", comment: "Accessibility label for result count / scroll-to-top button; %d = count"), activeMatchKinds.isEmpty ? total : visibleCount))
                .accessibilityHint(NSLocalizedString("search.a11y.scrollTop.hint", comment: "Accessibility hint for scroll to top button"))

                // Match-kind filter chips — only when 2+ kinds are present
                if presentKinds.count > 1 {
                    matchKindChipRow(presentKinds: presentKinds)
                        .padding(.bottom, DSSpacing.sm)
                }

                ForEach(groups, id: \.section) { group in
                    Section {
                        ForEach(group.results) { result in
                            let appeared = appearedIDs.contains(result.id)
                            resultRow(result)
                                // Hairline rows sit flush (the row draws its
                                // own 0.5pt bottom rule), so the per-card bottom
                                // gap is gone; horizontal inset relaxes from xl
                                // to lg to match the ledger rhythm.
                                .padding(.horizontal, DSSpacing.lg)
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
                                .foregroundColor(DSColor.inkMuted)
                            Rectangle()
                                .fill(DSColor.inkFaint)
                                .frame(height: 0.5)
                        }
                        .padding(.horizontal, DSSpacing.xl)
                        .padding(.vertical, DSSpacing.sm)
                        // Pinned header needs an opaque-ish mask over the
                        // ambient ground — material keeps the warmth visible.
                        .background(.ultraThinMaterial)
                    }
                }
            }
            .padding(.bottom, DSSpacing.xl2)
        }
        .scrollDismissesKeyboard(.interactively)
        } // end ScrollViewReader
    }

    private func matchKindChipRow(presentKinds: Set<SearchResult.MatchKind>) -> some View {
        let kindOrder: [SearchResult.MatchKind] = [.memoBody, .location, .date]
        let orderedKinds = kindOrder.filter { presentKinds.contains($0) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(orderedKinds, id: \.self) { kind in
                    matchKindChip(kind)
                }
            }
            .padding(.horizontal, DSSpacing.xl)
            .padding(.vertical, 2)
        }
    }

    private func matchKindChip(_ kind: SearchResult.MatchKind) -> some View {
        let isActive = activeMatchKinds.contains(kind)
        let kindCount = vm.results.filter { $0.matchKind == kind }.count
        let label = "\(matchLabel(for: kind)) \(kindCount)"
        return Button(action: {
            Haptics.soft()
            withAnimation(reduceMotion ? nil : Motion.spring) {
                if isActive {
                    activeMatchKinds.remove(kind)
                } else {
                    activeMatchKinds.insert(kind)
                }
            }
            let newVisible = activeMatchKinds.isEmpty ? vm.results.count
                : vm.results.filter { activeMatchKinds.contains($0.matchKind) }.count
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: String(format: NSLocalizedString("search.a11y.resultCount", comment: "VoiceOver: result count announcement"), newVisible))
            }
        }) {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: matchIcon(for: kind))
                    .font(.system(size: 10))
                Text(label)
                    .monoLabelStyle(size: 10)
            }
            .foregroundColor(isActive ? DSColor.onAmber : DSColor.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? DSColor.amberDeep : DSColor.glassLo, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(format: NSLocalizedString("search.a11y.kindChip", comment: "Accessibility label for match kind chip; %1$@ = kind label, %2$d = count"), matchLabel(for: kind), kindCount))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityHint(isActive ? NSLocalizedString("search.a11y.kindChip.deselect.hint", comment: "Accessibility hint to deselect kind filter") : NSLocalizedString("search.a11y.kindChip.select.hint", comment: "Accessibility hint to select kind filter"))
    }

    private func resultRow(_ result: SearchResult) -> some View {
        let badgeLabel = result.isDailyPageCompiled
            ? NSLocalizedString("search.badge.compiled", comment: "Result badge: day has a compiled daily page")
            : NSLocalizedString("search.badge.raw", comment: "Result badge: day has raw memos only")
        let a11yLabel = String(
            format: NSLocalizedString("search.a11y.resultRow", comment: "Result row a11y: date, match kind, compile state, snippet"),
            formatDate(result.dateString), matchLabel(for: result.matchKind), badgeLabel, String(result.snippet.prefix(80))
        )
        // W1: the 4pt alarm-bar + hard gray slab becomes a warm glass card;
        // the date takes the serif voice. The memo-type icon pair is shown
        // only when it adds information — "MEMO doc + TEXT doc" was the same
        // glyph twice.
        return Button(action: {
            Haptics.tapConfirm()
            vm.recordSearch(vm.query)
            onSelect(result.dateString)
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatDate(result.dateString))
                        .font(DSFonts.serif(size: 15, weight: .semibold, relativeTo: .subheadline))
                        .foregroundColor(DSColor.inkPrimary)
                    Spacer()
                    Text(badgeLabel)
                        .monoLabelStyle(size: 9)
                        .foregroundColor(result.isDailyPageCompiled ? DSColor.accentOnBg : DSColor.inkMuted)
                }

                highlightedSnippet(result.snippet, keyword: vm.query)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Image(systemName: matchIcon(for: result.matchKind))
                        .font(.system(size: 10))
                        .foregroundColor(DSColor.inkMuted)
                    Text(matchLabel(for: result.matchKind))
                        .monoLabelStyle(size: 10)
                        .foregroundColor(DSColor.inkMuted)

                    if let type = result.memoType, type != .text {
                        Image(systemName: type.iconName)
                            .font(.system(size: 10))
                            .foregroundColor(DSColor.inkMuted)
                        Text(type.displayName.uppercased())
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.inkMuted)
                    }
                }
            }
            // §4 density: the heavy 16pt-all-sides glass card is dropped for a
            // hairline row in the archive's own visual language. Search results
            // were a denser, glossier surface than the archive list they sit
            // beside; now both read as the same ledger. Content stays multi-line
            // (date · snippet · match kind) so nothing is lost — only the
            // container weight comes down, packing more hits per screen.
            .padding(.vertical, 13)
            .padding(.horizontal, DSSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityHint(NSLocalizedString("search.a11y.resultRow.hint", comment: "Accessibility hint for a search result row"))
    }

    // MARK: - Keyword highlight via AttributedString

    /// Delegates to SearchService's canonical folding so the highlighter can
    /// never drift from what the service actually matched (#827 dedup).
    private func foldedForSearch(_ s: String) -> String {
        SearchService.foldForSearch(s)
    }

    @ViewBuilder
    private func highlightedSnippet(_ snippet: String, keyword: String) -> some View {
        // Fold raw markdown out of the excerpt first — backticks, task
        // boxes and `---` dividers read as garbage in a one-line teaser
        // (M1 renders memo bodies, but snippets bypassed that pipeline).
        // Windowing + highlight offsets then operate on the cleaned text.
        let cleaned = Self.strippedLineArtifacts(MemoMarkdown.plainText(snippet))
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Text(cleaned)
                .bodySMStyle()
                .foregroundColor(DSColor.inkPrimary)
        } else {
            let windowed = snippetWindow(cleaned, keyword: trimmed)
            Text(buildHighlightedString(windowed, keyword: trimmed))
                .bodySMStyle()
        }
    }

    /// Upstream snippet generation collapses newlines to spaces, so
    /// line-level markdown (dividers, task boxes, heading hashes) loses the
    /// line boundary `MemoMarkdown.plainText` needs to recognise it — the
    /// tokens survive as mid-line litter (" --- ", "- [x] "). Salvage pass.
    static func strippedLineArtifacts(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"(^|\s)-{3,}(\s|$)"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(^|\s)- \[[ xX]\]\s"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(^|\s)#{1,4}\s"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Returns a ~80-char window of `snippet` centered just before the first folded match of
    /// `keyword`, so the highlight is always visible even for diacritic/width/case differences.
    /// Prepends/appends '…' when the window doesn't reach the string boundaries.
    /// Falls back to the original snippet when `keyword` is not found.
    private func snippetWindow(_ snippet: String, keyword: String, context: Int = 24) -> String {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return snippet }

        let foldedSnippet = foldedForSearch(snippet)
        let foldedKw = foldedForSearch(kw)

        // Locate the match in the folded string, then map the character offset back to original.
        // Folding with these options is 1:1 per character, so character-distance mapping is safe.
        guard let foldedRange = foldedSnippet.range(of: foldedKw) else { return snippet }

        let matchOffset = foldedSnippet.distance(from: foldedSnippet.startIndex, to: foldedRange.lowerBound)
        let windowStartOffset = max(0, matchOffset - context)

        let windowStart = snippet.index(snippet.startIndex, offsetBy: windowStartOffset)
        let windowEnd = snippet.index(windowStart,
                                      offsetBy: 80,
                                      limitedBy: snippet.endIndex) ?? snippet.endIndex

        var result = String(snippet[windowStart..<windowEnd])
        if windowStart != snippet.startIndex { result = "…" + result }
        if windowEnd != snippet.endIndex { result += "…" }
        return result
    }

    private func buildHighlightedString(_ text: String, keyword: String) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = UIColor(DSColor.inkPrimary)

        let foldedText = foldedForSearch(text)
        let foldedKeyword = foldedForSearch(keyword)
        guard !foldedKeyword.isEmpty else { return attributed }

        var searchStart = foldedText.startIndex
        while searchStart < foldedText.endIndex,
              let range = foldedText.range(of: foldedKeyword, range: searchStart..<foldedText.endIndex) {
            // Folding is 1:1 per character for these options — character offset is safe to map back.
            let offset = foldedText.distance(from: foldedText.startIndex, to: range.lowerBound)
            let length = foldedText.distance(from: range.lowerBound, to: range.upperBound)

            let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let attrEnd = attributed.index(attrStart, offsetByCharacters: length)
            let attrRange = attrStart..<attrEnd

            // W1: amber underline + semibold instead of a 28% background
            // wash — crisper, and it needs no dark-mode recolouring.
            // SwiftUI-scope LineStyle: the UIKit underline attributes are
            // not reliably rendered by SwiftUI `Text`.
            attributed[attrRange].foregroundColor = UIColor(DSColor.accentOnBg)
            attributed[attrRange].underlineStyle = Text.LineStyle(pattern: .solid, color: DSColor.amberAccent)
            // Scaled font keeps highlight emphasis in lockstep with the snippet's Dynamic Type size.
            attributed[attrRange].font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))

            searchStart = range.upperBound
        }

        return attributed
    }

    // MARK: - Starter suggestions (shown only when no history and no indexed entities)

    /// Localized starter chips, parsed from a comma-separated string so each locale supplies
    /// terms users in that language would actually type. Falls back to the English defaults.
    private static let starterSuggestions: [String] = {
        let raw = NSLocalizedString("search.starterSuggestions", comment: "Comma-separated starter search suggestions")
        let parsed = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parsed.isEmpty ? ["Today", "This Week", "This Month", "Place", "Photo", "Voice"] : parsed
    }()

    // MARK: - Formatting helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .long
        return f
    }()

    private func formatDate(_ dateString: String) -> String {
        guard let date = DateFormatters.isoDate.date(from: dateString) else { return dateString }
        let cal = Calendar.current
        let now = Date()
        let startOfDate = cal.startOfDay(for: date)
        let startOfToday = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0
        switch days {
        case 0:
            return NSLocalizedString("search.result.today", comment: "Search result date label for today")
        case 1:
            return NSLocalizedString("search.result.yesterday", comment: "Search result date label for yesterday")
        case 2...6:
            return String(format: NSLocalizedString("search.result.daysAgo", comment: "Search result date label for N days ago"), days)
        default:
            return SearchView.dateFormatter.string(from: date)
        }
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
        case .memoBody: return NSLocalizedString("search.matchKind.memo", comment: "Match-kind label: keyword hit in memo body")
        case .location: return NSLocalizedString("search.matchKind.location", comment: "Match-kind label: keyword hit in location name")
        case .date:     return NSLocalizedString("search.matchKind.date", comment: "Match-kind label: keyword hit on the date string")
        }
    }
}

// MARK: - EntityFrequencyChip

private struct EntityFrequencyChip: View {

    let entity: EntityFrequency
    let ratio: CGFloat
    let index: Int
    let reduceMotion: Bool
    let a11yLabel: String
    let action: () -> Void

    @State private var barAppeared: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: DSSpacing.xs) {
                HStack(spacing: 6) {
                    Text(entity.name)
                        .font(DSFonts.inter(size: 13, relativeTo: .footnote))
                        .foregroundColor(DSColor.inkPrimary)

                    Text("\(entity.count)")
                        .font(DSType.mono10)
                        .foregroundColor(DSColor.inkMuted)
                        .padding(.horizontal, DSSpacing.xs)
                        .padding(.vertical, 2)
                        .background(DSColor.outlineVariant.opacity(0.4))
                        .clipShape(Capsule())
                }

                // Frequency bar — fixed-height track with proportional foreground fill
                GeometryReader { geo in
                    let chipWidth = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(DSColor.outlineVariant.opacity(0.25))
                            .frame(width: chipWidth, height: 3)

                        Capsule()
                            .fill(DSColor.accentOnBg)
                            .frame(width: barAppeared ? chipWidth * ratio : 0, height: 3)
                            .animation(
                                reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.72)
                                    .delay(Double(index) * 0.04),
                                value: barAppeared
                            )
                    }
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .dpGlass(.pill, in: Capsule())
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11yLabel)
        .onAppear {
            if reduceMotion {
                barAppeared = true
            } else {
                withAnimation(
                    .spring(response: 0.45, dampingFraction: 0.72)
                        .delay(Double(index) * 0.04)
                ) {
                    barAppeared = true
                }
            }
        }
    }
}

// MARK: - ChipButtonStyle

private struct ChipButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : Motion.spring, value: configuration.isPressed)
    }
}

// MARK: - EntityChipSkeleton

private struct EntityChipSkeleton: View {

    let reduceMotion: Bool

    @State private var pulsing: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.sm) {
                ForEach(0..<4, id: \.self) { _ in
                    Capsule()
                        .fill(DSColor.surfaceContainer)
                        .frame(width: 80, height: 28)
                        .opacity(pulsing ? 0.45 : 0.85)
                }
            }
            .padding(.horizontal, DSSpacing.xl)
            .padding(.vertical, 10)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(
                .easeInOut(duration: 0.85)
                    .repeatForever(autoreverses: true)
            ) {
                pulsing = true
            }
        }
    }
}

// MARK: - SwipeableRecentRow

private struct SwipeableRecentRow: View {

    let query: String
    let index: Int
    let appeared: Bool
    let reduceMotion: Bool
    let onSelect: (String) -> Void
    let onDelete: () -> Void
    let onAppeared: () -> Void

    private let revealWidth: CGFloat = 64
    private let snapThreshold: CGFloat = 32

    @State private var revealed: Bool = false
    @GestureState private var drag: CGFloat = 0

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
            .accessibilityLabel(NSLocalizedString("search.a11y.deleteRecent", comment: "Accessibility label for delete recent search button"))

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
                        .font(DSFonts.inter(size: 14, relativeTo: .subheadline))
                        .foregroundColor(DSColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button(action: {
                    Haptics.warn()
                    withAnimation(reduceMotion ? nil : snapAnimation) { onDelete() }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(DSColor.outline)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChipButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel(NSLocalizedString("search.a11y.deleteRecent", comment: "Accessibility label for delete recent search button"))
            }
            .padding(.horizontal, DSSpacing.xl)
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
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .onAppear {
            guard !appeared else { return }
            let delay = Double(index) * 0.05
            if reduceMotion {
                onAppeared()
            } else {
                withAnimation(Motion.rise.delay(delay)) {
                    onAppeared()
                }
            }
        }
    }
}

// MARK: - SearchViewModel.GroupedResults: Identifiable

extension SearchViewModel.GroupedResults: Identifiable {
    var id: SearchViewModel.Section { section }
}

// MARK: - Testable folding helper

extension SearchView {
    /// Exposed for unit testing only — delegates to the canonical service fold.
    static func foldedForSearchTesting(_ s: String) -> String {
        SearchService.foldForSearch(s)
    }
}

// MARK: - Memo.MemoType + UI helpers

private extension Memo.MemoType {
    static let filterOptions: [Memo.MemoType] = [.text, .voice, .photo, .location]

    var displayName: String {
        switch self {
        case .text:     return NSLocalizedString("search.type.text", comment: "Memo type filter chip: text")
        case .voice:    return NSLocalizedString("search.type.voice", comment: "Memo type filter chip: voice")
        case .photo:    return NSLocalizedString("search.type.photo", comment: "Memo type filter chip: photo")
        case .location: return NSLocalizedString("search.type.location", comment: "Memo type filter chip: location")
        case .mixed:    return NSLocalizedString("search.type.mixed", comment: "Memo type filter chip: mixed")
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

// MARK: - NumericTextContentTransition

private struct NumericTextContentTransition: ViewModifier {
    let value: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .contentTransition(reduceMotion ? .identity : .numericText(value: value))
        } else {
            content
                .contentTransition(.identity)
        }
    }
}
