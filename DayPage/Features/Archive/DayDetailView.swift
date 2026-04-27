import SwiftUI

// MARK: - DayDetailView

/// 归档中某一天历日期的统一详情视图。
/// 在出现时异步加载，并解析为四种明确状态之一
/// — compiled, rawOnly, empty, error — 每种状态有各自的视图。
struct DayDetailView: View {

    let dateString: String

    @Environment(\.dismiss) private var dismiss

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

    @State private var state: LoadState = .loading
    @State private var hasRawFile: Bool = false
    @State private var selectedTab: Tab = .daily

    // 严格匹配 YYYY-MM-DD，零填充。
    private static let dateRegex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()

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
            .navigationTitle(formattedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(DSColor.onSurface)
                    }
                }
            }
        }
        .task { await load() }
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
            DailyPageView(dateString: dateString)
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
            RawMemoView(dateString: dateString)
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
        // 每次出现只加载一次；如果已解析，保持状态。
        guard state == .loading else { return }

        let target = dateString
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
        guard let date = fmt.date(from: dateString) else { return dateString }
        let out = DateFormatter()
        out.dateFormat = "MM.dd"
        out.locale = Locale(identifier: "zh_CN")
        return out.string(from: date)
    }
}
