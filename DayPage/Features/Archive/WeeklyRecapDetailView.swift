import SwiftUI

// MARK: - WeeklyRecapDetailView
//
// Detail screen pushed from ArchiveView's weekly recap entry card.
// Loads the cached weekly recap if present, otherwise triggers a fresh
// AI compile. Three states — loading / error / success — are surfaced
// inline rather than via overlay so the screen stays scrollable.
//
// Why a dedicated view (not a sheet): the recap is a first-class artifact
// alongside Daily Page detail screens; reading + recompile should feel
// like a navigated page, not a transient modal.
struct WeeklyRecapDetailView: View {

    let referenceDate: Date

    @State private var output: WeeklyRecapOutput?
    @State private var isLoading: Bool = false
    /// R8-LOW: detailed error — drives both the inline copy and the
    /// retry-affordance. Kept alongside the legacy `error` string so the
    /// localizedDescription fallback still works when callers throw an
    /// unmodelled error.
    @State private var detailedError: WeeklyCompilationError?
    @State private var error: String?

    /// R8-MEDIUM B2: pushed when a keyword chip / place row is tapped.
    /// Drives a `.sheet` of `EntityPageView`. Slug is lowercased + trimmed
    /// before resolve so cache hits work the same way DailyPage's wikilink
    /// resolver does.
    @State private var entityNavSlug: String?
    @State private var entityNavType: String = "themes"

    /// R8-LOW: monitor the network so the offline error auto-retries the
    /// moment connectivity returns. The view drops the subscription on
    /// dismiss; `.onChange` of `isOnline` fires only while this view is
    /// alive.
    @StateObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if isLoading {
                    loadingState
                } else if let detailed = detailedError {
                    detailedErrorState(detailed)
                } else if let err = error {
                    errorState(message: err)
                } else if let output = output {
                    sections(output: output)
                    refreshButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(DSColor.backgroundWarm.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("weekly.recap.title", comment: ""))
        .task {
            await loadInitial()
        }
        // R8-LOW B3: when the network comes back online and we're parked on
        // the .offline error state, auto-retry once so the user doesn't have
        // to spot the wifi icon themselves. Only fires online edges (false→true).
        .onChange(of: networkMonitor.isOnline) { isOnline in
            guard isOnline else { return }
            guard case .offline = detailedError else { return }
            Task { await reload(forceRefresh: false) }
        }
        // R8-MEDIUM B2: keyword chip / place row taps push EntityPageView
        // as a sheet (mirrors DailyPageView's wikilink behaviour). The
        // slug→type resolve happens in `handleKeywordTap`; sheet item is
        // the slug so a quick re-tap re-presents cleanly.
        .sheet(isPresented: Binding(
            get: { entityNavSlug != nil },
            set: { if !$0 { entityNavSlug = nil } }
        )) {
            if let slug = entityNavSlug {
                EntityPageView(entityType: entityNavType, entitySlug: slug)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        let rangeText = output?.dateRange
            ?? Self.fallbackDateRange(for: referenceDate)
        let isoWeek = output?.isoWeek
            ?? WeeklyCompilationService.isoWeekKey(for: referenceDate)

        return VStack(alignment: .leading, spacing: 6) {
            Text("📅 \(NSLocalizedString("weekly.recap.title", comment: ""))")
                .font(DSType.headlineMD)
                .foregroundColor(DSColor.inkPrimary)
            Text("\(isoWeek) · \(rangeText)")
                .font(DSType.mono11)
                .foregroundColor(DSColor.inkSubtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(NSLocalizedString("weekly.recap.title", comment: "")), \(isoWeek), \(rangeText)")
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text(NSLocalizedString("weekly.recap.loading", comment: ""))
                .font(DSType.bodyMD)
                .foregroundColor(DSColor.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NSLocalizedString("weekly.recap.loading", comment: ""))
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(DSColor.statusError)
            Text(NSLocalizedString("weekly.recap.error.body", comment: ""))
                .font(DSType.bodyMD)
                .foregroundColor(DSColor.inkPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkMuted)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button {
                Task { await reload(forceRefresh: true) }
            } label: {
                Text(NSLocalizedString("weekly.recap.refresh", comment: ""))
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.amberAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DSColor.amberRim, lineWidth: 1)
                    )
            }
            .accessibilityHint(NSLocalizedString("weekly.recap.refresh.hint", comment: ""))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("weekly.recap.error.body", comment: ""))
    }

    @ViewBuilder
    private func sections(output: WeeklyRecapOutput) -> some View {
        keywordsSection(output.keywords)
        moodSection(output.moodNotes)
        placesSection(output.placeNotes)
        highlightsSection(output.highlights)
    }

    // MARK: - Sections

    private func keywordsSection(_ keywords: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(NSLocalizedString("weekly.recap.section.keywords", comment: ""))
            keywordChipFlow(keywords)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("weekly.recap.section.keywords.a11y", comment: ""))
    }

    private func keywordChipFlow(_ keywords: [String]) -> some View {
        // Wrap-around HStack via VStack rows of ~3 chips — simple and
        // dependency-free; flow layout was excessive for the current
        // 3-5-chip case.
        //
        // R8-MEDIUM B2: each chip is a Button → push EntityPageView via
        // the shared `handleKeywordTap` slug-resolver. Wrapped with
        // `.buttonStyle(.plain)` so the chip visual stays identical to
        // the original `Text(kw)` rendering.
        let rows = Self.chunk(keywords, size: 3)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<rows.count, id: \.self) { rowIdx in
                HStack(spacing: 8) {
                    ForEach(rows[rowIdx], id: \.self) { kw in
                        Button {
                            handleKeywordTap(kw)
                        } label: {
                            Text(kw)
                                .font(DSType.bodyMD)
                                .foregroundColor(DSColor.amberAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(DSColor.amberAccent.opacity(0.14))
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(kw))
                        .accessibilityHint(Text(NSLocalizedString(
                            "weekly.recap.keyword.hint",
                            value: "打开实体页",
                            comment: "VoiceOver hint for tapping a weekly recap keyword chip"
                        )))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func moodSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(NSLocalizedString("weekly.recap.section.mood", comment: ""))
            Text(text.isEmpty ? "—" : text)
                .font(DSType.bodyMD)
                .foregroundColor(DSColor.inkPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(DSColor.amberAccent.opacity(0.06))
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("weekly.recap.section.mood.a11y", comment: ""))
    }

    private func placesSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(NSLocalizedString("weekly.recap.section.places", comment: ""))
            // R8-MEDIUM B2: the place row is interactive. We pick the first
            // non-empty noun-ish token from `placeNotes` as the slug —
            // mirrors the heuristic used by keyword chips. The whole row is
            // a Button so the mappin icon + text are tappable as one unit.
            let firstPlace = Self.firstPlaceToken(from: text)
            Button {
                guard let p = firstPlace, !p.isEmpty else { return }
                handlePlaceTap(p)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mappin")
                        .font(.system(size: 16))
                        .foregroundColor(DSColor.amberAccent)
                        .padding(.top, 2)
                    Text(text.isEmpty ? "—" : text)
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(firstPlace == nil || (firstPlace?.isEmpty ?? true))
            .accessibilityHint(Text(NSLocalizedString(
                "weekly.recap.place.hint",
                value: "打开地点页",
                comment: "VoiceOver hint for tapping the weekly recap place row"
            )))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("weekly.recap.section.places.a11y", comment: ""))
    }

    private func highlightsSection(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(NSLocalizedString("weekly.recap.section.highlights", comment: ""))
            ForEach(0..<items.count, id: \.self) { idx in
                HStack(alignment: .top, spacing: 8) {
                    Text("✦")
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.amberAccent)
                    Text(items[idx])
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("weekly.recap.section.highlights.a11y", comment: ""))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(DSType.sectionLabel)
            .foregroundColor(DSColor.inkMuted)
            .tracking(1.2)
    }

    private var refreshButton: some View {
        HStack {
            Spacer()
            Button {
                Task { await reload(forceRefresh: true) }
            } label: {
                Text(NSLocalizedString("weekly.recap.refresh", comment: ""))
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.amberAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(DSColor.amberRim, lineWidth: 1)
                    )
            }
            .accessibilityHint(NSLocalizedString("weekly.recap.refresh.hint", comment: ""))
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Loading logic

    private func loadInitial() async {
        if let cached = WeeklyCompilationService.shared.loadCached(for: referenceDate) {
            self.output = cached
            return
        }
        await reload(forceRefresh: false)
    }

    private func reload(forceRefresh: Bool) async {
        isLoading = true
        error = nil
        detailedError = nil
        do {
            let result = try await WeeklyCompilationService.shared.compileWeekly(
                for: referenceDate,
                forceRefresh: forceRefresh
            )
            self.output = result
        } catch let typed as WeeklyCompilationError {
            // R8-LOW B3: surface specific case so the UI can show targeted copy.
            self.detailedError = typed
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Detailed Error State (R8-LOW B3)

    @ViewBuilder
    private func detailedErrorState(_ err: WeeklyCompilationError) -> some View {
        let copy = Self.copy(for: err)
        VStack(spacing: 12) {
            Image(systemName: copy.systemImage)
                .font(.system(size: 32))
                .foregroundColor(copy.iconColor)
            Text(copy.title)
                .font(DSType.bodyMD)
                .foregroundColor(DSColor.inkPrimary)
                .multilineTextAlignment(.center)
            if let detail = copy.detail {
                Text(detail)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            if copy.showRetry {
                Button {
                    Task { await reload(forceRefresh: true) }
                } label: {
                    Text(NSLocalizedString("weekly.recap.refresh", comment: ""))
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.amberAccent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(DSColor.amberRim, lineWidth: 1)
                        )
                }
                .accessibilityHint(NSLocalizedString("weekly.recap.refresh.hint", comment: ""))
            } else if case .offline = err {
                // Spinner mirrors NetworkMonitor waiting state.
                HStack(spacing: 8) {
                    ProgressView()
                    Text(NSLocalizedString(
                        "weekly.recap.error.offline.waiting",
                        value: "等待网络恢复…",
                        comment: "Inline waiting label when offline; auto-retries on isOnline edge"
                    ))
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.inkMuted)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy.title)
    }

    /// Static mapping from `WeeklyCompilationError` → user-facing copy.
    /// Kept static so unit tests can pin the string lookups without
    /// spinning up the view.
    static func copy(for err: WeeklyCompilationError) -> ErrorCopy {
        switch err {
        case .noData:
            return ErrorCopy(
                title: NSLocalizedString(
                    "weekly.recap.error.noData",
                    value: "本周还没有足够日记（至少需要 3 天）",
                    comment: "Weekly recap error: not enough daily pages"
                ),
                detail: nil,
                systemImage: "doc.text",
                iconColor: DSColor.inkMuted,
                showRetry: false
            )
        case .offline:
            return ErrorCopy(
                title: NSLocalizedString(
                    "weekly.recap.error.offline",
                    value: "等待网络恢复…",
                    comment: "Weekly recap error: offline (auto-retries when online)"
                ),
                detail: NSLocalizedString(
                    "weekly.recap.error.offline.detail",
                    value: "网络恢复后会自动重新编译",
                    comment: "Weekly recap offline detail line"
                ),
                systemImage: "wifi.slash",
                iconColor: DSColor.statusError,
                showRetry: false
            )
        case .aiDisabled:
            return ErrorCopy(
                title: NSLocalizedString(
                    "weekly.recap.error.aiDisabled",
                    value: "AI 功能已关闭",
                    comment: "Weekly recap error: AI features disabled in Settings"
                ),
                detail: NSLocalizedString(
                    "weekly.recap.error.aiDisabled.detail",
                    value: "请在设置中重新启用 AI 编译",
                    comment: "Weekly recap aiDisabled detail line"
                ),
                systemImage: "sparkles",
                iconColor: DSColor.inkMuted,
                showRetry: false
            )
        case .missingApiKey:
            return ErrorCopy(
                title: NSLocalizedString(
                    "weekly.recap.error.missingApiKey",
                    value: "尚未配置 API 密钥",
                    comment: "Weekly recap error: missing API key"
                ),
                detail: NSLocalizedString(
                    "weekly.recap.error.missingApiKey.detail",
                    value: "请在设置 → API 密钥中填入 DeepSeek 密钥",
                    comment: "Weekly recap missingApiKey detail line"
                ),
                systemImage: "key.slash",
                iconColor: DSColor.statusError,
                showRetry: false
            )
        case .networkTimeout:
            return ErrorCopy(
                title: NSLocalizedString(
                    "weekly.recap.error.networkTimeout",
                    value: "网络请求超时，点击重试",
                    comment: "Weekly recap error: network timeout"
                ),
                detail: nil,
                systemImage: "clock.arrow.circlepath",
                iconColor: DSColor.statusError,
                showRetry: true
            )
        case .apiRateLimited:
            return ErrorCopy(
                title: NSLocalizedString(
                    "weekly.recap.error.rateLimited",
                    value: "请求过于频繁，请稍后再试",
                    comment: "Weekly recap error: API rate limited"
                ),
                detail: nil,
                systemImage: "hourglass",
                iconColor: DSColor.statusError,
                showRetry: true
            )
        case .apiError(let code, let body):
            let fmt = NSLocalizedString(
                "weekly.recap.error.llmFailed",
                value: "AI 服务暂时无响应（%@），点击重试",
                comment: "Weekly recap error: LLM API non-2xx; %@ = short reason"
            )
            let reason = "HTTP \(code)"
            return ErrorCopy(
                title: String(format: fmt, reason),
                detail: String(body.prefix(120)),
                systemImage: "exclamationmark.triangle",
                iconColor: DSColor.statusError,
                showRetry: true
            )
        case .parseFailed(let msg):
            return ErrorCopy(
                title: NSLocalizedString(
                    "weekly.recap.error.parseFailed",
                    value: "AI 返回内容无法解析，点击重试",
                    comment: "Weekly recap error: LLM JSON parse failed"
                ),
                detail: msg,
                systemImage: "doc.badge.gearshape",
                iconColor: DSColor.statusError,
                showRetry: true
            )
        case .fileSystemError(let msg):
            return ErrorCopy(
                title: NSLocalizedString(
                    "weekly.recap.error.fileSystem",
                    value: "文件写入失败，点击重试",
                    comment: "Weekly recap error: cannot write to vault"
                ),
                detail: msg,
                systemImage: "internaldrive",
                iconColor: DSColor.statusError,
                showRetry: true
            )
        case .unknown(let underlying):
            return ErrorCopy(
                title: NSLocalizedString(
                    "weekly.recap.error.unknown",
                    value: "出现未知错误，点击重试",
                    comment: "Weekly recap error: unknown wrapped error"
                ),
                detail: underlying.localizedDescription,
                systemImage: "questionmark.circle",
                iconColor: DSColor.statusError,
                showRetry: true
            )
        }
    }

    /// Static value type so error → copy mapping is testable without SwiftUI.
    struct ErrorCopy {
        let title: String
        let detail: String?
        let systemImage: String
        let iconColor: Color
        let showRetry: Bool
    }

    // MARK: - Entity Navigation (R8-MEDIUM B2)

    /// Resolve the slug → entity type by probing the vault's wiki tree
    /// (matches the heuristic in DailyPageView). Falls back to "themes"
    /// when no concrete entity page exists yet — the empty-state of
    /// EntityPageView will surface the right "not generated" message.
    private func handleKeywordTap(_ keyword: String) {
        let slug = keyword.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return }
        let (type, resolved) = Self.resolveEntityTypeAndSlug(slug)
        entityNavType = type
        entityNavSlug = resolved
    }

    /// Place row tap → push EntityPageView under "places" preferentially.
    private func handlePlaceTap(_ raw: String) {
        let slug = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return }
        let (type, resolved) = Self.resolveEntityTypeAndSlug(slug, preferPlaces: true)
        entityNavType = type
        entityNavSlug = resolved
    }

    /// Mirrors DailyPageView.resolveEntityTypeAndSlug. Static so we can hit
    /// it without instantiating the view, and so unit tests can pin the
    /// fallback order ("places" → "people" → "themes").
    static func resolveEntityTypeAndSlug(
        _ inner: String,
        preferPlaces: Bool = false
    ) -> (type: String, slug: String) {
        let slug = inner.contains("|")
            ? String(inner.split(separator: "|", maxSplits: 1).first ?? Substring(inner))
            : inner
        let wikiBase = VaultInitializer.vaultURL.appendingPathComponent("wiki")
        let types = preferPlaces
            ? ["places", "people", "themes"]
            : ["places", "people", "themes"]
        for type in types {
            let url = wikiBase.appendingPathComponent(type).appendingPathComponent("\(slug).md")
            if FileManager.default.fileExists(atPath: url.path) {
                return (type, slug)
            }
        }
        return (preferPlaces ? "places" : "themes", slug)
    }

    /// First plausible place token from the LLM's free-form `placeNotes`.
    /// Picks the first non-empty Chinese/English run separated by punctuation;
    /// returns nil when nothing usable is present.
    static func firstPlaceToken(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Punctuation/whitespace split — keep it loose so we accept "上海、北京"
        // or "Tokyo, Kyoto" with equal grace.
        let sep = CharacterSet(charactersIn: "，。 、.,;；\n\t")
        for token in trimmed.components(separatedBy: sep) {
            let cand = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if cand.count >= 2 { return cand }
        }
        return nil
    }

    // MARK: - Helpers

    private static func fallbackDateRange(for date: Date) -> String {
        let cal = WeeklyCompilationService.weekCalendar
        guard let interval = cal.dateInterval(of: .weekOfYear, for: date) else {
            return ""
        }
        let start = cal.startOfDay(for: interval.start)
        guard let end = cal.date(byAdding: .day, value: 6, to: start) else { return "" }
        let f = WeeklyCompilationService.dateFormatter
        return "\(f.string(from: start)) to \(f.string(from: end))"
    }

    private static func chunk<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0, !array.isEmpty else { return [] }
        var result: [[T]] = []
        var i = 0
        while i < array.count {
            let end = min(i + size, array.count)
            result.append(Array(array[i..<end]))
            i = end
        }
        return result
    }
}
