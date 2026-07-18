import SwiftUI
import DayPageStorage
import DayPageServices

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
//
// 2026-07-18 杂志编排重构（Apple design）：
//  - Hero 头部：衬线大字周标题 + 编号眼睫毛 + ISO周·日期范围，占首屏视觉重心。
//  - 每节带 `NN` 编号 + 章节名的杂志式分节，板块间大留白呼吸。
//  - 补齐两块此前从未渲染的字段：`reflectionQuestions`(本周 5 问，点击回写
//    Today composer) 与 `outliers`(值得回看的孤峰，引用式高光卡)。注释一直
//    声称这里渲染 5 问，但呈现层从未接上 —— 现补齐。
//  - 顶栏材质化：navigationBar 半透明 + 内容滚动其下；进场时 hero 元素做
//    轻微上浮 + 淡入，呼应从归档卡 push 进来的空间连续性。
//  - 边缘返回：入口已 `.restoresInteractivePop()`，此处不再叠加手势。
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

    /// 进场动画开关。首帧为 false，`.onAppear` 里翻 true 触发 hero + 分节的
    /// 上浮淡入 —— 从归档卡 push 进来时的空间连续感（§7 spatial consistency）。
    @State private var appeared: Bool = false

    /// W1: keyword chip / place row taps push an `EntityRef` onto the host
    /// (Archive) stack instead of opening a local sheet — inherits system back
    /// + edge-pop. Slug is lowercased + trimmed before resolve so cache hits
    /// work the same way DailyPage's wikilink resolver does.
    @EnvironmentObject private var nav: AppNavigationModel

    /// R8-LOW: monitor the network so the offline error auto-retries the
    /// moment connectivity returns. The view drops the subscription on
    /// dismiss; `.onChange` of `isOnline` fires only while this view is
    /// alive.
    @StateObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .padding(.horizontal, DSSpacing.xl)
                    .padding(.top, DSSpacing.lg)

                if isLoading {
                    loadingState
                } else if let detailed = detailedError {
                    detailedErrorState(detailed)
                } else if let err = error {
                    errorState(message: err)
                } else if let output = output {
                    sections(output: output)
                        .padding(.top, DSSpacing.xl2)
                    footer(output: output)
                }
            }
            .padding(.bottom, 48)
        }
        .background(DSColor.backgroundWarm.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("weekly.recap.title", comment: ""))
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .task {
            await loadInitial()
        }
        .onAppear {
            // 进场 hero：只在首次出现时播一次。用 Motion.rise 的柔和曲线做
            // 内容上浮，避免弹跳（非动量交互，§4 critically-damped）。
            guard !appeared else { return }
            withAnimation(Motion.rise.delay(0.04)) { appeared = true }
        }
        // R8-LOW B3: when the network comes back online and we're parked on
        // the .offline error state, auto-retry once so the user doesn't have
        // to spot the wifi icon themselves. Only fires online edges (false→true).
        .onChange(of: networkMonitor.isOnline) { isOnline in
            guard isOnline else { return }
            guard case .offline = detailedError else { return }
            Task { await reload(forceRefresh: false) }
        }
    }

    // MARK: - Hero
    //
    // Magazine masthead: a small mono eyebrow, a large serif week title, and
    // an ISO-week · date-range dateline. This is the page's visual anchor —
    // it earns the top of the fold the way a Daily Page's hero date does.
    private var hero: some View {
        let rangeText = output?.dateRange
            ?? Self.fallbackDateRange(for: referenceDate)
        let isoWeek = output?.isoWeek
            ?? WeeklyCompilationService.isoWeekKey(for: referenceDate)

        return VStack(alignment: .leading, spacing: 10) {
            // Eyebrow — mono, wide-tracked, quiet.
            Text(NSLocalizedString("weekly.recap.hero.eyebrow", comment: "")
                .uppercased())
                .font(DSType.mono11)
                .tracking(2.4)
                .foregroundColor(DSColor.accentOnBg)

            // Serif week title — the masthead. Ranges like "06.22 – 06.28"
            // read as a magazine issue span.
            Text(Self.heroRangeTitle(from: rangeText, fallback: referenceDate))
                .font(DSType.serifDisplay32)
                .foregroundColor(DSColor.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Dateline — ISO week + full range, mono, muted.
            Text("\(isoWeek) · \(rangeText)")
                .font(DSType.mono11)
                .foregroundColor(DSColor.inkMuted)
                .padding(.top, 2)

            // Hairline rule closes the masthead off from the body — a thin
            // amber rule, not a full-width grey divider (§12 scroll edges over
            // hard dividers).
            Rectangle()
                .fill(DSColor.amberRim)
                .frame(width: 44, height: 2)
                .padding(.top, DSSpacing.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(NSLocalizedString("weekly.recap.title", comment: "")), \(isoWeek), \(rangeText)")
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: DSSpacing.md) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(DSColor.accentOnBg)
            Text(NSLocalizedString("weekly.recap.loading", comment: ""))
                .font(DSType.bodyMD)
                .foregroundColor(DSColor.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NSLocalizedString("weekly.recap.loading", comment: ""))
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: DSSpacing.md) {
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
            retryButton
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, 64)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("weekly.recap.error.body", comment: ""))
    }

    @ViewBuilder
    private func sections(output: WeeklyRecapOutput) -> some View {
        // Ordered as a magazine table of contents. Numbers are assigned in
        // render order and skip sections with no content, so a recap missing
        // outliers still numbers 01…04 cleanly.
        let blocks = Self.orderedBlocks(for: output)
        VStack(alignment: .leading, spacing: DSSpacing.xl2 + DSSpacing.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                section(number: idx + 1, block: block, output: output)
                    // Stagger the rise so blocks cascade in rather than
                    // popping as one slab (§8 hint in the direction of motion).
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
                    .animation(Motion.rise.delay(0.06 + Double(idx) * 0.04), value: appeared)
            }
        }
        .padding(.horizontal, DSSpacing.xl)
    }

    @ViewBuilder
    private func section(number: Int, block: Block, output: WeeklyRecapOutput) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            sectionHeader(number: number, title: block.title)
            switch block {
            case .keywords:    keywordFlow(output.keywords)
            case .reflections: reflectionsBody(output.reflectionQuestions)
            case .mood:        moodBody(output.moodNotes)
            case .places:      placesBody(output.placeNotes)
            case .highlights:  highlightsBody(output.highlights)
            case .outliers:    outliersBody(output.outliers)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.a11yTitle)
    }

    // MARK: - Section header (magazine numbering)

    private func sectionHeader(number: Int, title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(format: NSLocalizedString("weekly.recap.section.number.format", comment: ""), number))
                .font(DSType.mono11)
                .foregroundColor(DSColor.accentOnBg)
            Text(title.uppercased())
                .font(DSType.sectionLabel)
                .tracking(1.5)
                .foregroundColor(DSColor.inkMuted)
            Rectangle()
                .fill(DSColor.inkFaint)
                .frame(height: 1)
        }
    }

    // MARK: - Keywords (true flow)

    private func keywordFlow(_ keywords: [String]) -> some View {
        // Real wrap-around flow layout replaces the old "3 per row" chunking:
        // chips now pack tightly and wrap on width, so a 7-word week no longer
        // leaves ragged half-empty rows. Each chip is a Button → push
        // EntityPageView via the shared `handleKeywordTap` slug-resolver.
        FlowLayout(spacing: DSSpacing.sm) {
            ForEach(keywords, id: \.self) { kw in
                Button {
                    Haptics.selection()
                    handleKeywordTap(kw)
                } label: {
                    Text(kw)
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.accentOnBg)
                        .padding(.horizontal, DSSpacing.md)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(DSColor.amberAccent.opacity(0.12))
                        )
                        .overlay(
                            Capsule().stroke(DSColor.amberRim, lineWidth: 1)
                        )
                }
                .pressScale(scale: 0.94, opacity: 0.9, animation: Motion.press)
                .accessibilityLabel(Text(kw))
                .accessibilityHint(Text(NSLocalizedString(
                    "weekly.recap.keyword.hint",
                    value: "打开实体页",
                    comment: "VoiceOver hint for tapping a weekly recap keyword chip"
                )))
            }
        }
    }

    // MARK: - Reflections (本周 5 问 — newly rendered)

    private func reflectionsBody(_ questions: [String]) -> some View {
        // Each question is a tappable card. Tapping routes to Today with the
        // question pre-filled into the composer (via the official
        // `pendingDraftText` rail — the same track QuickCapture / capture
        // reminders use), so the answer becomes a fresh memo. This finally
        // wires up the interaction the model comment promised since Issue #9.
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            ForEach(Array(questions.enumerated()), id: \.offset) { idx, q in
                Button {
                    Haptics.tapConfirm()
                    handleReflectionTap(q)
                } label: {
                    HStack(alignment: .top, spacing: DSSpacing.md) {
                        Text(String(format: "%02d", idx + 1))
                            .font(DSType.mono11)
                            .foregroundColor(DSColor.accentOnBg)
                            .padding(.top, 3)
                        Text(q)
                            .font(DSType.bodyMD)
                            .foregroundColor(DSColor.inkPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DSColor.inkSubtle)
                            .padding(.top, 3)
                    }
                    .padding(DSSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                            .fill(DSColor.surfaceWhite)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                            .stroke(DSColor.borderSubtle, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
                }
                .pressScale(scale: 0.98, opacity: 0.95, animation: Motion.press)
                .accessibilityLabel(Text(q))
                .accessibilityHint(Text(NSLocalizedString(
                    "weekly.recap.reflection.hint",
                    value: "带着这个问题去写一段",
                    comment: "VoiceOver hint for tapping a reflection question"
                )))
            }
        }
    }

    // MARK: - Mood

    private func moodBody(_ text: String) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(DSType.serifBody16)
            .foregroundColor(DSColor.inkPrimary)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .fill(DSColor.amberAccent.opacity(0.06))
            )
    }

    // MARK: - Places

    private func placesBody(_ text: String) -> some View {
        // R8-MEDIUM B2: the place row is interactive. We pick the first
        // non-empty noun-ish token from `placeNotes` as the slug. The whole
        // row is a Button so the mappin icon + text are tappable as one unit.
        let firstPlace = Self.firstPlaceToken(from: text)
        return Button {
            guard let p = firstPlace, !p.isEmpty else { return }
            Haptics.selection()
            handlePlaceTap(p)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 15))
                    .foregroundColor(DSColor.accentOnBg)
                    .padding(.top, 2)
                Text(text.isEmpty ? "—" : text)
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DSSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .fill(DSColor.surfaceWhite)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .stroke(DSColor.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        }
        .pressScale(scale: 0.98, opacity: 0.95, animation: Motion.press)
        .disabled(firstPlace == nil || (firstPlace?.isEmpty ?? true))
        .accessibilityHint(Text(NSLocalizedString(
            "weekly.recap.place.hint",
            value: "打开地点页",
            comment: "VoiceOver hint for tapping the weekly recap place row"
        )))
    }

    // MARK: - Highlights

    private func highlightsBody(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            ForEach(0..<items.count, id: \.self) { idx in
                HStack(alignment: .top, spacing: DSSpacing.md) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DSColor.accentOnBg)
                        .padding(.top, 3)
                    Text(items[idx])
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Issue #8 (2026-07-03): long-press an insight to convert
                // it into tomorrow's todo. Service writes the memo,
                // haptic confirms, banner surfaces "已加入明日".
                .contextMenu {
                    Button {
                        do {
                            _ = try InsightActionService.convertToTomorrowTodo(
                                insight: items[idx],
                                source: "weekly-highlights"
                            )
                            Haptics.commit()
                            BannerCenter.shared.show(.init(
                                kind: .info,
                                title: "已加入明日待办",
                                autoDismiss: true
                            ))
                        } catch {
                            BannerCenter.shared.show(.init(
                                kind: .error,
                                title: "加入待办失败：\(error.localizedDescription)",
                                autoDismiss: true
                            ))
                        }
                    } label: {
                        Label("变成明日待办", systemImage: "checklist")
                    }
                }
            }
        }
    }

    // MARK: - Outliers (值得回看的孤峰 — newly rendered)

    private func outliersBody(_ items: [String]) -> some View {
        // Quote-style cards: low-frequency, high-signal moments the ordinary
        // highlight extractor drops. A left amber rule + serif italic gives
        // them the weight of a pull-quote — the opposite tone of the compact
        // highlight bullets, on purpose.
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            ForEach(0..<items.count, id: \.self) { idx in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DSColor.amberRim)
                        .frame(width: 3)
                    Text(items[idx])
                        .font(DSType.serifBody16)
                        .foregroundColor(DSColor.inkPrimary)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, DSSpacing.md)
                        .padding(.vertical, 2)
                }
                .padding(.vertical, DSSpacing.xs)
            }
        }
    }

    // MARK: - Footer (compiled-at + recompile)

    private func footer(output: WeeklyRecapOutput) -> some View {
        VStack(spacing: DSSpacing.lg) {
            Text(String(
                format: NSLocalizedString("weekly.recap.compiled.at.format", comment: ""),
                Self.compiledAtLabel(output.compiledAt)
            ))
            .font(DSType.mono10)
            .foregroundColor(DSColor.inkSubtle)

            retryButton
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, DSSpacing.xl)
        .opacity(appeared ? 1 : 0)
        .animation(Motion.fade.delay(0.28), value: appeared)
    }

    /// Shared recompile affordance — used by success footer and every error
    /// state so the button never drifts between contexts.
    private var retryButton: some View {
        Button {
            Haptics.tapConfirm()
            Task { await reload(forceRefresh: true) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                Text(NSLocalizedString("weekly.recap.refresh", comment: ""))
                    .font(DSType.labelSM)
            }
            .foregroundColor(DSColor.accentOnBg)
            .padding(.horizontal, DSSpacing.xl)
            .padding(.vertical, 10)
            .overlay(
                Capsule().stroke(DSColor.amberRim, lineWidth: 1)
            )
        }
        .pressScale(scale: 0.96, opacity: 0.92, animation: Motion.press)
        .accessibilityHint(NSLocalizedString("weekly.recap.refresh.hint", comment: ""))
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
        VStack(spacing: DSSpacing.md) {
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
                retryButton
            } else if case .offline = err {
                // Spinner mirrors NetworkMonitor waiting state.
                HStack(spacing: DSSpacing.sm) {
                    ProgressView()
                        .tint(DSColor.accentOnBg)
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
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, 64)
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

    // MARK: - Section model
    //
    // Blocks are the magazine "articles". `orderedBlocks` keeps only the ones
    // with content so numbering never gaps, and fixes the read order:
    // keywords → reflections → mood → places → highlights → outliers.
    enum Block {
        case keywords
        case reflections
        case mood
        case places
        case highlights
        case outliers

        var title: String {
            switch self {
            case .keywords:    return NSLocalizedString("weekly.recap.section.keywords", comment: "")
            case .reflections: return NSLocalizedString("weekly.recap.section.reflections", comment: "")
            case .mood:        return NSLocalizedString("weekly.recap.section.mood", comment: "")
            case .places:      return NSLocalizedString("weekly.recap.section.places", comment: "")
            case .highlights:  return NSLocalizedString("weekly.recap.section.highlights", comment: "")
            case .outliers:    return NSLocalizedString("weekly.recap.section.outliers", comment: "")
            }
        }

        var a11yTitle: String {
            switch self {
            case .keywords:    return NSLocalizedString("weekly.recap.section.keywords.a11y", comment: "")
            case .reflections: return NSLocalizedString("weekly.recap.section.reflections.a11y", comment: "")
            case .mood:        return NSLocalizedString("weekly.recap.section.mood.a11y", comment: "")
            case .places:      return NSLocalizedString("weekly.recap.section.places.a11y", comment: "")
            case .highlights:  return NSLocalizedString("weekly.recap.section.highlights.a11y", comment: "")
            case .outliers:    return NSLocalizedString("weekly.recap.section.outliers.a11y", comment: "")
            }
        }
    }

    /// Render order + content gating. A block only appears when it carries
    /// content, so an old cached recap without reflections/outliers still
    /// numbers its present sections 01…N with no holes.
    static func orderedBlocks(for output: WeeklyRecapOutput) -> [Block] {
        var blocks: [Block] = []
        if !output.keywords.isEmpty { blocks.append(.keywords) }
        if !output.reflectionQuestions.isEmpty { blocks.append(.reflections) }
        if !output.moodNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.mood) }
        if !output.placeNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.places) }
        if !output.highlights.isEmpty { blocks.append(.highlights) }
        if !output.outliers.isEmpty { blocks.append(.outliers) }
        return blocks
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
        nav.push(EntityRef(type: type, slug: resolved), in: nav.selectedTab)
    }

    /// Place row tap → push EntityPageView under "places" preferentially.
    private func handlePlaceTap(_ raw: String) {
        let slug = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return }
        let (type, resolved) = Self.resolveEntityTypeAndSlug(slug, preferPlaces: true)
        nav.push(EntityRef(type: type, slug: resolved), in: nav.selectedTab)
    }

    /// Reflection question tap → route to Today with the question pre-filled
    /// into the composer. Uses `pendingDraftText`, the same official rail the
    /// QuickCapture intent and capture reminders drive, so the answer becomes
    /// a fresh memo. This is the interaction the model comment on
    /// `reflectionQuestions` promised (Issue #9) but the view never wired up.
    private func handleReflectionTap(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        nav.navigate(to: .today)
        nav.pendingDraftText = trimmed
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

    /// Turn a raw "2026-06-22 to 2026-06-28" range into a compact masthead
    /// title "06.22 – 06.28". Falls back to the reference date's own
    /// month.day when the range can't be parsed.
    static func heroRangeTitle(from range: String, fallback: Date) -> String {
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd"
        let parts = range.components(separatedBy: " to ")
        if parts.count == 2,
           let start = iso.date(from: parts[0].trimmingCharacters(in: .whitespaces)),
           let end = iso.date(from: parts[1].trimmingCharacters(in: .whitespaces)) {
            let md = DateFormatter()
            md.locale = Locale(identifier: "en_US_POSIX")
            md.dateFormat = "MM.dd"
            return "\(md.string(from: start)) – \(md.string(from: end))"
        }
        let md = DateFormatter()
        md.locale = Locale(identifier: "en_US_POSIX")
        md.dateFormat = "MM.dd"
        return md.string(from: fallback)
    }

    /// "MM-dd HH:mm" compiled-at label, local time zone.
    static func compiledAtLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}
