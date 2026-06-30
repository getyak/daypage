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
        case daily = "Daily Page"
        case raw = "原始 Memo"
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

    @State private var state: LoadState = .loading
    @State private var hasRawFile: Bool = false
    @State private var selectedTab: Tab = .daily

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
    private static let dateRegex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

    var body: some View {
        NavigationStack {
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
            }
            // Horizontal swipe to page between days. High distance + low-ish
            // height tolerance keeps it from stealing vertical scrolls inside
            // the daily/raw content.
            .simultaneousGesture(pageSwipeGesture)
            .navigationTitle(formattedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(DSColor.onSurface)
                    }
                    .accessibilityLabel("返回")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: { go(.backward) }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(DSColor.onSurface)
                    }
                    .accessibilityLabel("前一天")

                    Button(action: { go(.forward) }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(canGoForward ? DSColor.onSurface : DSColor.onSurfaceVariant.opacity(0.35))
                    }
                    .disabled(!canGoForward)
                    .accessibilityLabel("后一天")
                }
            }
        }
        .task(id: currentDate) { await load() }
    }

    // MARK: - Day Paging

    /// Local "today" as a `yyyy-MM-dd` string — the forward cap. Future days
    /// can hold no content, so the `›` affordance stops here.
    private var todayString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        return fmt.string(from: Date())
    }

    /// Forward paging is allowed only while we're strictly before today.
    private var canGoForward: Bool { currentDate < todayString }

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

    private var pageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                // Treat as horizontal only when the drag is dominantly sideways.
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5,
                      abs(value.translation.width) > 60 else { return }
                if value.translation.width < 0 {
                    go(.forward)   // drag left → next (later) day
                } else {
                    go(.backward)  // drag right → previous (earlier) day
                }
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
        withAnimation(reduceMotion ? nil : Motion.slide) {
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
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current

        guard let base = fmt.date(from: dateString) else { return nil }
        let delta = forward ? 1 : -1
        guard let next = Calendar.current.date(byAdding: .day, value: delta, to: base) else { return nil }

        let nextString = fmt.string(from: next)
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
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
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
                MetadataGridView()
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 6)
                DailyPageView(dateString: currentDate)
            }
        case .rawOnly:
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "doc.text")
                    .font(.system(size: 40))
                    .foregroundColor(DSColor.onSurfaceVariant.opacity(0.5))
                Text("这一天还没编译")
                    .headlineCapsStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
                Button(action: { selectedTab = .raw }) {
                    Text("查看原始 Memo")
                        .font(.custom("JetBrainsMono-Regular", fixedSize: 13))
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
                Text("这一天没有记录")
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
            Text("这一天还没有记录")
                .headlineCapsStyle()
                .foregroundColor(DSColor.onSurfaceVariant)
            Button(action: { dismiss() }) {
                Text("关闭")
                    .font(.custom("JetBrainsMono-Regular", fixedSize: 13))
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
            Text("无法加载这一天")
                .headlineCapsStyle()
                .foregroundColor(DSColor.onSurface)
            Text(message)
                .font(.custom("JetBrainsMono-Regular", fixedSize: 11))
                .foregroundColor(DSColor.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(action: { dismiss() }) {
                Text("关闭")
                    .font(.custom("JetBrainsMono-Regular", fixedSize: 13))
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
    }

    /// 纯解析器 — 不含 SwiftUI，不含异步。返回 `(state, hasRawFile)`。
    /// 以模块内部可见性暴露，以便 `@testable import DayPage` 可以
    /// 覆盖 4 种加载状态而无需启动视图。
    static func resolveLoadState(dateString: String,
                                 vaultURL: URL,
                                 fileManager: FileManager) -> (LoadState, Bool) {
        // 1. 严格校验 dateString 格式。
        let range = NSRange(dateString.startIndex..., in: dateString)
        guard dateRegex.firstMatch(in: dateString, options: [], range: range) != nil else {
            return (.error("日期格式无效：\(dateString)"), false)
        }

        // 2. 使用 DateFormatter 交叉校验（捕获 '2020-02-30' 等）。
        // 使用设备时区，确保日期边界与文件命名方式对齐。
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone.current
        parser.isLenient = false
        guard parser.date(from: dateString) != nil else {
            return (.error("日期不存在：\(dateString)"), false)
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
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = fmt.date(from: currentDate) else { return currentDate }
        let out = DateFormatter()
        out.dateFormat = "MM.dd"
        out.locale = Locale(identifier: "zh_CN")
        return out.string(from: date)
    }
}
