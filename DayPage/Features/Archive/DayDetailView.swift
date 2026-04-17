import SwiftUI

// MARK: - DayDetailView

/// Unified detail view for a calendar date in Archive.
/// Loads asynchronously on appear and resolves into one of four explicit states
/// — compiled, rawOnly, empty, error — each with its own view.
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

    // Matches strict YYYY-MM-DD, zero-padded.
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
        // Only load once per appearance; if already resolved, keep state.
        guard state == .loading else { return }

        // 1. Validate dateString format strictly.
        let range = NSRange(dateString.startIndex..., in: dateString)
        guard Self.dateRegex.firstMatch(in: dateString, options: [], range: range) != nil else {
            state = .error("日期格式无效：\(dateString)")
            return
        }

        // 2. Cross-check with DateFormatter (catches '2020-02-30' etc.).
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.isLenient = false
        guard parser.date(from: dateString) != nil else {
            state = .error("日期不存在：\(dateString)")
            return
        }

        // 3. Async file existence probes off the main thread.
        let target = dateString
        let (dailyExists, rawExists, failureDetail) = await Task.detached(priority: .userInitiated) { () -> (Bool, Bool, String?) in
            let vault = VaultInitializer.vaultURL
            let dailyURL = vault
                .appendingPathComponent("wiki")
                .appendingPathComponent("daily")
                .appendingPathComponent("\(target).md")
            let rawURL = vault
                .appendingPathComponent("raw")
                .appendingPathComponent("\(target).md")
            let fm = FileManager.default
            let dailyOK = fm.fileExists(atPath: dailyURL.path)
            let rawOK = fm.fileExists(atPath: rawURL.path)

            // Sanity-check the vault directory itself — unreachable vault = .error.
            var isDir: ObjCBool = false
            let vaultOK = fm.fileExists(atPath: vault.path, isDirectory: &isDir) && isDir.boolValue
            if !vaultOK {
                let detail = "vault unreachable: \(vault.path) (errno=\(errno))"
                return (false, false, detail)
            }
            return (dailyOK, rawOK, nil)
        }.value

        if let detail = failureDetail {
            DayPageLogger.shared.error("DayDetailView: \(detail)")
            state = .error("存储初始化失败")
            return
        }

        hasRawFile = rawExists
        if dailyExists {
            state = .compiled
            selectedTab = .daily
        } else if rawExists {
            state = .rawOnly
            selectedTab = .raw
        } else {
            state = .empty
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
