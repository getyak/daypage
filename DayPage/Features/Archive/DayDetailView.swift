import SwiftUI
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - DayDetailView

/// 归档中某一天历日期的统一详情视图。
/// 在出现时异步加载，并解析为四种明确状态之一
/// — compiled, rawOnly, empty, error — 每种状态有各自的视图。
struct DayDetailView: View {

    /// The day this detail view was opened on. The view can page away from it
    /// (see `currentDate`); every caller still presents a single date.
    let dateString: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var nav: AppNavigationModel

    enum Tab: String, CaseIterable {
        // 同一控件内半英半中（"Daily Page" | "原始 Memo"）读起来像两个产品
        // （FINDING-010）。可交互控件在每个语言内保持整体一致 — 经 L10n 解析。
        case daily
        case raw

        var title: String {
            switch self {
            case .daily: return NSLocalizedString("daydetail.tab.daily", comment: "Segment title: compiled daily page")
            case .raw:   return NSLocalizedString("daydetail.tab.raw", comment: "Segment title: raw memos")
            }
        }
    }

    enum LoadState: Equatable {
        case loading
        case compiled        // daily file exists (raw may or may not exist)
        case rawOnly         // no daily, but raw exists
        case empty           // valid date, nothing on disk
        case error(String)   // invalid dateString or IO failure
    }

    /// Direction the currently-displayed day arrived from — drives the slide
    /// transition. `.forward` = moved to a later day, `.backward` = earlier.
    private enum PageDirection { case forward, backward }

    /// Live state of an in-flight page drag. `isEngaged` latches once the drag
    /// is dominantly horizontal so a finger that later wanders vertically keeps
    /// tracking instead of dropping the page mid-gesture.
    private struct PageDragState: Equatable {
        var isEngaged = false
        var offset: CGFloat = 0
    }

    @State private var state: LoadState = .loading
    @State private var hasRawFile: Bool = false
    @State private var selectedTab: Tab = .daily
    /// 当天真实元数据瓦片（天气/条数/跨度/类型），无 raw 数据时为 nil 并隐藏。
    @State private var metaTiles: [MetadataGridView.Tile]? = nil

    /// Finger-tracked horizontal offset for interactive paging. `@GestureState`
    /// auto-resets when the gesture ends or is cancelled; the reset transaction
    /// springs the page back to rest (near-instant under Reduce Motion).
    @GestureState(resetTransaction: Transaction(animation: Motion.respectReduceMotion(Motion.spring)))
    private var pageDrag = PageDragState()

    /// The day actually on screen. Initialised to `dateString`, then advanced /
    /// rewound by `go(_:)`. Re-running `load()` keyed on this value lets a
    /// single presentation walk to any adjacent calendar day.
    @State private var currentDate: String
    @State private var lastDirection: PageDirection = .forward

    init(dateString: String) {
        self.dateString = dateString
        _currentDate = State(initialValue: dateString)
    }

    // 严格匹配 YYYY-MM-DD，零填充。
    private static let dateRegex = try? NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

    var body: some View {
        // No inner NavigationStack — DayDetailView is now pushed onto the host's
        // stack (Today / Archive both root a NavigationStack), so it inherits
        // the system back button AND the interactive edge-swipe-to-pop that a
        // self-contained modal `fullScreenCover` could never offer. The leading
        // "返回" chevron is gone because the system back button replaces it; the
        // ›/‹ day-stepper toolbar stays on the trailing side.
        ZStack {
            DSColor.background.ignoresSafeArea()

            Group {
                switch state {
                case .loading:
                    loadingView
                case .compiled, .rawOnly:
                    loadedContent
                case .empty:
                    emptyStateView
                case .error(let message):
                    errorStateView(message: message)
                }
            }
            // Re-key on the displayed day so SwiftUI treats each day as a
            // distinct subtree and runs the directional slide transition.
            .id(currentDate)
            .transition(dayTransition)
            // Finger-tracked paging: 1:1 while paging is possible in the
            // drag direction, rubber-banded at the bounds (see gesture).
            .offset(x: pageDrag.offset)
        }
        // Interactive horizontal paging between days: the page follows the
        // finger once the drag is dominantly sideways, rubber-bands at the
        // bounds, and commits on distance or flick. `simultaneousGesture`
        // + the dominance gate keep vertical scrolls inside the daily/raw
        // content untouched.
        .simultaneousGesture(pageSwipeGesture)
        .navigationTitle(formattedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: { go(.backward) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DSColor.onSurface)
                }
                .accessibilityLabel(NSLocalizedString("daydetail.a11y.prevDay", comment: "A11y label: go to previous day"))

                Button(action: { go(.forward) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(canGoForward ? DSColor.onSurface : DSColor.onSurfaceVariant.opacity(0.35))
                }
                .disabled(!canGoForward)
                .accessibilityLabel(NSLocalizedString("daydetail.a11y.nextDay", comment: "A11y label: go to next day"))
            }
        }
        .task(id: currentDate) { await load() }
    }

    // MARK: - Day Paging

    /// Local "today" as a `yyyy-MM-dd` string — the forward cap. Future days
    /// can hold no content, so the `›` affordance stops here.
    private var todayString: String {
        DateFormatters.isoDate.string(from: Date())
    }

    /// Forward paging is allowed only while we're strictly before today.
    private var canGoForward: Bool { currentDate < todayString }

    /// Backward paging is allowed whenever a valid previous calendar day
    /// exists — the same bounds check `go(.backward)` performs.
    private var canGoBackward: Bool {
        Self.steppedDate(from: currentDate, forward: false) != nil
    }

    /// Slide the incoming day in from the side it came from; fade only when the
    /// user has Reduce Motion on.
    private var dayTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let insertEdge: Edge = lastDirection == .forward ? .trailing : .leading
        let removeEdge: Edge = lastDirection == .forward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertEdge).combined(with: .opacity),
            removal: .move(edge: removeEdge).combined(with: .opacity)
        )
    }

    /// Rubber-band factor applied when dragging toward a bound that cannot page.
    private static let boundsResistance: CGFloat = 0.3

    private var pageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: DSGesture.pagerMinimumDistance)
            .updating($pageDrag) { value, drag, _ in
                // Engage only once the drag is dominantly sideways, so we never
                // fight vertical scrolling inside the daily/raw content; after
                // that, latch and follow the finger for the rest of the gesture.
                if !drag.isEngaged {
                    guard abs(value.translation.width) > abs(value.translation.height) * DSGesture.horizontalDominance else { return }
                    drag.isEngaged = true
                }
                let translation = value.translation.width
                // drag left → forward (later day); drag right → backward.
                let canPage = translation < 0 ? canGoForward : canGoBackward
                drag.offset = canPage ? translation : translation * Self.boundsResistance
            }
            .onEnded { value in
                // Same horizontal-dominance guard as tracking: an end that never
                // engaged (vertical scroll) must stay a no-op.
                guard abs(value.translation.width) > abs(value.translation.height) * DSGesture.horizontalDominance else { return }
                let screenWidth = UIScreen.main.bounds.width
                let translation = value.translation.width
                // `value.velocity` is iOS 17+; the predicted overshoot is the
                // deceleration-projected distance, so a projection past half the
                // screen reads as a decisive flick even from a short drag.
                let projected = value.predictedEndTranslation.width
                let commit = abs(translation) > screenWidth / 3 || abs(projected) > screenWidth / 2
                guard commit else { return }  // @GestureState springs offset back to 0
                // `go(_:)` re-checks the bounds itself, so a committed drag at a
                // bound stays the same silent no-op as before.
                go(translation < 0 ? .forward : .backward)
            }
    }

    /// Advance or rewind `currentDate` by one calendar day. Forward is capped at
    /// today; an out-of-range step is a silent no-op (the affordance is disabled
    /// rather than buzzing).
    private func go(_ direction: PageDirection) {
        let forward = direction == .forward
        guard let nextString = Self.steppedDate(
            from: currentDate,
            forward: forward,
            notAfter: forward ? todayString : nil
        ) else { return }

        Haptics.soft()
        lastDirection = direction
        // Spring (not a fixed timing curve) so a finger-tracked commit settles
        // with continuous-feeling velocity instead of restarting from zero.
        withAnimation(reduceMotion ? nil : Motion.spring) {
            state = .loading        // show the loader while the next day resolves
            currentDate = nextString
        }
    }

    /// Pure date stepper for paging. Returns the `yyyy-MM-dd` string one calendar
    /// day after (`forward`) or before (`!forward`) `dateString`, or `nil` when
    /// the step is impossible or out of range. Calendar-aware, so month/year
    /// rollover (e.g. `2026-02-28` → `2026-03-01`) is handled for free.
    ///
    /// - Parameter notAfter: optional inclusive upper bound (the forward cap —
    ///   typically "today"). A result beyond it returns `nil` so callers stop at
    ///   the boundary. Lexicographic compare is valid for zero-padded ISO dates.
    /// - Returns: the adjacent day, or `nil` if `dateString` is unparseable, the
    ///   step lands on the same string, or it exceeds `notAfter`.
    static func steppedDate(from dateString: String,
                            forward: Bool,
                            notAfter: String? = nil) -> String? {
        guard let base = DateFormatters.isoDate.date(from: dateString) else { return nil }
        let delta = forward ? 1 : -1
        guard let next = Calendar.current.date(byAdding: .day, value: delta, to: base) else { return nil }

        let nextString = DateFormatters.isoDate.string(from: next)
        guard nextString != dateString else { return nil }
        if let cap = notAfter, nextString > cap { return nil }
        return nextString
    }

    // MARK: - Loaded Content (compiled / rawOnly)

    @ViewBuilder
    private var loadedContent: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedTab) { _ in Haptics.selection() }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DSColor.surfaceContainerLow)

            Divider().background(DSColor.outline)

            Group {
                switch selectedTab {
                case .daily:
                    dailyContent
                case .raw:
                    rawContent
                }
            }
        }
    }

    @ViewBuilder
    private var dailyContent: some View {
        switch state {
        case .compiled:
            // v8 detail.jsx:258-271 — 4-column metadata tile row pinned above
            // the compiled daily page (WEATHER / HUMIDITY / LIGHT / KIND).
            VStack(spacing: 0) {
                if let tiles = metaTiles {
                    MetadataGridView(tiles: tiles)
                        .padding(.horizontal, 22)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                }
                DailyPageView(dateString: currentDate, isEmbedded: true)
            }
        case .rawOnly:
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "doc.text")
                    .font(.system(size: 40))
                    .foregroundColor(DSColor.onSurfaceVariant.opacity(0.5))
                Text(NSLocalizedString("daydetail.state.notCompiled", comment: "Empty state: day has raw memos but no compiled daily page"))
                    .headlineCapsStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
                Button(action: { selectedTab = .raw }) {
                    Text(NSLocalizedString("daydetail.state.viewRaw", comment: "Button: switch to the raw memo tab"))
                        .font(DSFonts.jetBrainsMono(size: 13, relativeTo: .footnote))
                        .foregroundColor(DSColor.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DSColor.primary, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rawContent: some View {
        if hasRawFile {
            RawMemoView(dateString: currentDate)
        } else {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 40))
                    .foregroundColor(DSColor.onSurfaceVariant.opacity(0.5))
                Text(NSLocalizedString("daydetail.raw.empty", comment: "Empty state: no raw memos on this day"))
                    .headlineCapsStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Loading / Empty / Error

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .tint(DSColor.onSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundColor(DSColor.onSurfaceVariant.opacity(0.6))
            Text(NSLocalizedString("daydetail.empty.title", comment: "Empty state: nothing logged on this day at all"))
                .headlineCapsStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
            Button(action: { dismiss() }) {
                Text(NSLocalizedString("daydetail.close", comment: "Button: dismiss the day detail view"))
                    .font(DSFonts.jetBrainsMono(size: 13, relativeTo: .footnote))
                    .foregroundColor(DSColor.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(DSColor.primary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorStateView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundColor(DSColor.error)
            Text(NSLocalizedString("daydetail.error.title", comment: "Error state title: the day failed to load"))
                .headlineCapsStyle()
                .foregroundColor(DSColor.onSurface)
            Text(message)
                .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                .foregroundColor(DSColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(action: { dismiss() }) {
                Text(NSLocalizedString("daydetail.close", comment: "Button: dismiss the day detail view"))
                    .font(DSFonts.jetBrainsMono(size: 13, relativeTo: .footnote))
                    .foregroundColor(DSColor.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(DSColor.primary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load

    private func load() async {
        // Resolve only while in the loading state. `go(_:)` resets to `.loading`
        // before bumping `currentDate`, so each paged day re-enters here; an
        // already-resolved day (re-fired task) keeps its state.
        guard state == .loading else { return }

        let target = currentDate
        let resolved = await Task.detached(priority: .userInitiated) { () -> (LoadState, Bool) in
            Self.resolveLoadState(dateString: target,
                                   vaultURL: VaultInitializer.vaultURL,
                                   fileManager: .default)
        }.value

        if case .error(let msg) = resolved.0 {
            DayPageLogger.shared.error("DayDetailView: \(msg)")
        }

        hasRawFile = resolved.1
        switch resolved.0 {
        case .compiled:
            state = .compiled
            selectedTab = .daily
        case .rawOnly:
            state = .rawOnly
            selectedTab = .raw
        case .empty, .error, .loading:
            state = resolved.0
        }

        // FINDING-004: the metadata strip previously rendered MetadataGridView's
        // design-reference defaults (28° / 86 PERCENT / …) — fabricated numbers
        // presented as this day's facts. Derive the tiles from the day's raw
        // memos instead; fields with no source data show "—".
        if resolved.1, let date = DateFormatters.isoDate.date(from: target) {
            let memos = await Task.detached(priority: .userInitiated) {
                (try? RawStorage.read(for: date)) ?? []
            }.value
            metaTiles = Self.buildMetaTiles(from: memos)
        } else {
            metaTiles = nil
        }
    }

    /// 从当天 raw memos 推导 4 块元数据（天气 / 条数 / 时间跨度 / 类型）。
    /// 纯函数，便于测试。
    static func buildMetaTiles(from memos: [Memo]) -> [MetadataGridView.Tile]? {
        guard !memos.isEmpty else { return nil }
        let sorted = memos.sorted { $0.created < $1.created }

        // WEATHER — first memo that captured one, e.g. "小雨 24°C"
        var weatherValue = "—", weatherSub: String? = nil
        if let w = sorted.compactMap(\.weather).first {
            let parts = w.split(separator: " ")
            if let temp = parts.first(where: { $0.contains("°") }) {
                weatherValue = String(temp)
                weatherSub = parts.first(where: { !$0.contains("°") }).map(String.init)
            } else {
                weatherValue = w
            }
        }

        // ENTRIES — memo count. Tile labels ("ENTRIES"/"SPAN"/"WEATHER"/"KIND")
        // are intentionally-untranslated archival tags (FINDING-010); values
        // and subs carry the localized content.
        let entriesTile = MetadataGridView.Tile(
            label: "ENTRIES", value: "\(sorted.count)", sub: "MEMOS"
        )

        // SPAN — first→last capture time
        let fmt = DateFormatters.timeHHmm
        let first = fmt.string(from: sorted.first!.created)
        let last = fmt.string(from: sorted.last!.created)
        let spanTile = MetadataGridView.Tile(
            label: "SPAN",
            value: sorted.count > 1 ? "\(first)" : first,
            sub: sorted.count > 1 ? "→ \(last)" : nil
        )

        // KIND — dominant memo type
        let voice = sorted.filter { $0.type == .voice }.count
        let photo = sorted.filter { $0.attachments.contains { $0.kind == "photo" } }.count
        let text = sorted.count - voice - photo
        let dominant: String = {
            if text >= voice && text >= photo { return NSLocalizedString("daydetail.kind.text", comment: "Dominant memo kind: text") }
            if voice >= photo { return NSLocalizedString("daydetail.kind.voice", comment: "Dominant memo kind: voice") }
            return NSLocalizedString("daydetail.kind.photo", comment: "Dominant memo kind: photo")
        }()
        var kindParts: [String] = []
        if text > 0 { kindParts.append(String(format: NSLocalizedString("daydetail.kind.part.text", comment: "Kind tile sub: %d text memos"), text)) }
        if voice > 0 { kindParts.append(String(format: NSLocalizedString("daydetail.kind.part.voice", comment: "Kind tile sub: %d voice memos"), voice)) }
        if photo > 0 { kindParts.append(String(format: NSLocalizedString("daydetail.kind.part.photo", comment: "Kind tile sub: %d photo memos"), photo)) }

        return [
            MetadataGridView.Tile(label: "WEATHER", value: weatherValue, sub: weatherSub),
            entriesTile,
            spanTile,
            MetadataGridView.Tile(label: "KIND", value: dominant, sub: kindParts.joined(separator: " · "))
        ]
    }

    /// 纯解析器 — 不含 SwiftUI，不含异步。返回 `(state, hasRawFile)`。
    /// 以模块内部可见性暴露，以便 `@testable import DayPage` 可以
    /// 覆盖 4 种加载状态而无需启动视图。
    static func resolveLoadState(dateString: String,
                                 vaultURL: URL,
                                 fileManager: FileManager) -> (LoadState, Bool) {
        // 1. 严格校验 dateString 格式。
        let range = NSRange(dateString.startIndex..., in: dateString)
        guard let dateRegex,
              dateRegex.firstMatch(in: dateString, options: [], range: range) != nil else {
            return (.error(String(format: NSLocalizedString("daydetail.error.badFormat", comment: "Error: date string is not yyyy-MM-dd; %@ = raw input"), dateString)), false)
        }

        // 2. 使用 DateFormatter 交叉校验（捕获 '2020-02-30' 等）。
        // 使用设备时区，确保日期边界与文件命名方式对齐。
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone.current
        parser.isLenient = false
        guard parser.date(from: dateString) != nil else {
            return (.error(String(format: NSLocalizedString("daydetail.error.notFound", comment: "Error: date does not exist on the calendar; %@ = raw input"), dateString)), false)
        }

        // 3. 检查 vault 目录完整性。
        var isDir: ObjCBool = false
        let vaultOK = fileManager.fileExists(atPath: vaultURL.path, isDirectory: &isDir) && isDir.boolValue
        if !vaultOK {
            let detail = "vault unreachable: \(vaultURL.path) (errno=\(errno))"
            return (.error(detail), false)
        }

        // 4. 探测 daily + raw 文件。
        let dailyURL = vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateString).md")
        let rawURL = vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("\(dateString).md")
        let dailyExists = fileManager.fileExists(atPath: dailyURL.path)
        let rawExists = fileManager.fileExists(atPath: rawURL.path)

        if dailyExists {
            return (.compiled, rawExists)
        } else if rawExists {
            return (.rawOnly, true)
        } else {
            return (.empty, false)
        }
    }

    // MARK: - Helpers

    private var formattedTitle: String {
        guard let date = DateFormatters.isoDate.date(from: currentDate) else { return currentDate }
        let out = DateFormatter()
        out.dateFormat = "MM.dd"
        out.locale = Locale(identifier: "zh_CN")
        return out.string(from: date)
    }
}
