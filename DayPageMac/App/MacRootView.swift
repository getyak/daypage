import SwiftUI
import DayPageModels
import DayPageServices
import DayPageStorage

// MARK: - MacRootView

/// Top-level Mac layout: NavigationSplitView with a sidebar (Today / Archive)
/// + a content column. The two-column split is the macOS-native idiom; the
/// iOS sidebar drawer pattern would feel wrong with a mouse + keyboard.
struct MacRootView: View {

    @EnvironmentObject private var cloudAuth: MacCloudAuthService
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var syncQueue = SyncQueueService.shared

    enum Section: String, CaseIterable, Identifiable {
        case today
        case archive

        var id: String { rawValue }

        var label: String {
            switch self {
            case .today:   return "今天"
            case .archive: return "归档"
            }
        }

        var systemImage: String {
            switch self {
            case .today:   return "sun.max"
            case .archive: return "calendar"
            }
        }
    }

    @State private var selection: Section? = .today
    @State private var showingSignIn = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Section.allCases) { section in
                    Label(section.label, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .navigationTitle("DayPage")
            .frame(minWidth: 180)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarAccountButton
            }
        } detail: {
            switch selection {
            case .today, .none:
                MacTodayView()
            case .archive:
                MacArchiveView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Center-of-titlebar mini logo + dropdown affordance (visual
                // only for now — mirrors the flomo `≡ flomo ⌄` look).
                HStack(spacing: 6) {
                    Image(systemName: "sun.haze.fill")
                        .foregroundStyle(.secondary)
                    Text("DayPage").fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                syncStatus
            }
            ToolbarItem(placement: .primaryAction) {
                Text("⌘K")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .help("搜索（暂未启用）")
            }
        }
        .sheet(isPresented: $showingSignIn) {
            MacAuthView()
                .environmentObject(cloudAuth)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, cloudAuth.session != nil else { return }
            Task { await SyncQueueService.shared.flushIfOnline() }
        }
        .onOpenURL { url in
            guard NativeAuthFlow.isCallback(url, for: .macOS) else { return }
            showingSignIn = true
            Task { await cloudAuth.handleAuthCallback(url) }
        }
        .alert(
            "无法开启云同步",
            isPresented: Binding(
                get: { cloudAuth.syncErrorMessage != nil },
                set: { if !$0 { cloudAuth.dismissSyncError() } }
            )
        ) {
            Button("好", role: .cancel) { cloudAuth.dismissSyncError() }
        } message: {
            Text(cloudAuth.syncErrorMessage ?? "")
        }
    }

    private var sidebarAccountButton: some View {
        Button {
            showingSignIn = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: cloudAuth.session == nil
                    ? "person.crop.circle.badge.plus"
                    : "person.crop.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        cloudAuth.session == nil
                            ? Color(nsColor: .secondaryLabelColor)
                            : Color.orange
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(cloudAuth.accountLabel ?? "仅本机账户")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(cloudAuth.session == nil ? "登录并开启同步" : "账户与同步")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(8)
        .background(.regularMaterial)
        .accessibilityLabel(cloudAuth.session == nil ? "仅本机账户，登录并开启同步" : "账户与同步")
    }

    @ViewBuilder
    private var syncStatus: some View {
        if syncQueue.isFlushingNow {
            Label("同步中", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        } else if cloudAuth.session == nil {
            Label(
                syncQueue.pendingCount == 0 ? "仅本地" : "本地已保存 · \(syncQueue.pendingCount) 条待登录",
                systemImage: "externaldrive"
            )
            .foregroundStyle(.secondary)
        } else if syncQueue.pendingCount > 0 {
            Button {
                cloudAuth.retrySync()
            } label: {
                Label("\(syncQueue.pendingCount) 条待同步", systemImage: "icloud.and.arrow.up")
            }
            .foregroundStyle(.orange)
        } else if syncQueue.completion.isFullySynced {
            // “已同步” only from the shared completion proof (#884): current
            // session, memo drained, metadata current, outbox 0, media done.
            Label("已同步", systemImage: "checkmark.icloud")
                .foregroundStyle(.green)
        } else {
            Button {
                cloudAuth.retrySync()
            } label: {
                Label("等待完整同步确认", systemImage: "icloud")
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Archive (day list + memo list + read-only detail)

/// Mac archive (#884): a natural day list over `vault/raw/*.md`, the owning
/// day's memos, and a read-only detail that keeps the ORIGINAL body fully
/// selectable/copyable plus exact tags and safe explicit media. Rows reuse
/// `MemoRow`/`MemoRowTagBar`/`MemoMediaList` from `MacTodayView` — no new
/// target files. Routing is ALWAYS `(memo UUID, owning day file)`: the day is
/// never recomputed from `created` or a timezone preference.
struct MacArchiveView: View {

    @State private var dayFiles: [String] = []
    @State private var selectedDay: String? = nil
    @State private var memos: [Memo] = []
    @State private var selectedMemoID: UUID? = nil
    @State private var detailMemo: Memo? = nil
    @State private var detailUnavailable = false
    @State private var loadError: String?

    var body: some View {
        HSplitView {
            dayList
                .frame(minWidth: 190, maxWidth: 260)
            memoList
                .frame(minWidth: 240, idealWidth: 300)
            detailPane
                .frame(minWidth: 320)
        }
        .navigationTitle("归档")
        .onAppear(perform: refresh)
        .onChange(of: selectedDay) { _ in
            loadSelectedDay()
        }
        .onReceive(NotificationCenter.default.publisher(for: .rawStorageDidWrite)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountTagProjectionDidUpdate)) { _ in
            // Projection changes refresh the detail's exact tag list.
            reloadDetail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .attachmentTransferStateDidChange)) { _ in
            reloadDetail()
        }
    }

    // MARK: Day list

    private var dayList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let err = loadError {
                Text(err).foregroundStyle(.secondary).padding(12)
            } else if dayFiles.isEmpty {
                Text("vault/raw/ 还是空的。先去今天写一条 memo。")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                List(dayFiles, id: \.self, selection: $selectedDay) { name in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.naturalDate(forDayKey: name))
                            .font(.system(size: 13))
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: Memo list (owning day)

    private var memoList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedDay == nil {
                Text("选择左侧的一天")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else if memos.isEmpty {
                Text("这一天没有 memo。")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(memos, id: \.id) { memo in
                            Button {
                                selectedMemoID = memo.id
                                reloadDetail()
                            } label: {
                                MemoRow(memo: memo)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        selectedMemoID == memo.id
                                            ? Color.accentColor.opacity(0.08)
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    // MARK: Read-only detail (original body, exact tags, safe media)

    @ViewBuilder
    private var detailPane: some View {
        if detailUnavailable {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("这条 memo 已不可用")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let memo = detailMemo {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(Self.timestamp(memo.created))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    let tags = MacTagReading.labels(memoID: memo.id)
                    if !tags.labels.isEmpty {
                        MemoRowTagBar(labels: tags.labels)
                    } else if tags.availability == .unavailable {
                        // Missing/corrupt/foreign metadata ≠ a memo with no
                        // tags — the unavailable state is explicit.
                        Label("标签信息暂不可用", systemImage: "icloud.slash")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    // ORIGINAL full body — exact bytes, selectable and
                    // copyable; the light markdown renderer never replaces
                    // the source of truth here.
                    Text(memo.body)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !memo.attachments.isEmpty {
                        MemoMediaList(attachments: memo.attachments)
                    }
                }
                .padding(20)
            }
        } else {
            Text("选择一条 memo 查看原文")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Loading

    private func refresh() {
        let url = VaultInitializer.vaultURL.appendingPathComponent("raw", isDirectory: true)
        do {
            let names = try FileManager.default
                .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .map { $0.lastPathComponent }
                .filter { $0.hasSuffix(".md") }
                .map { String($0.dropLast(3)) }
                .filter { RawStorage.isValidDayString($0) }
                .sorted(by: >)
            dayFiles = names
            loadError = nil
            if let selected = selectedDay, !names.contains(selected) {
                selectedDay = nil
                selectedMemoID = nil
                detailMemo = nil
            }
            loadSelectedDay()
        } catch {
            loadError = "读取 vault/raw 失败：\(error.localizedDescription)"
        }
    }

    private func loadSelectedDay() {
        guard let dayKey = selectedDay else {
            memos = []
            detailMemo = nil
            detailUnavailable = false
            return
        }
        // Owning-day read: the file name is the route key — `created` (and
        // any timezone preference) never retargets the lookup.
        let loaded = (try? RawStorage.read(dayString: dayKey, vaultRoot: VaultInitializer.vaultURL)) ?? []
        memos = loaded.sorted { $0.created > $1.created }
        reloadDetail()
    }

    private func reloadDetail() {
        guard selectedDay != nil, let memoID = selectedMemoID else {
            detailMemo = nil
            detailUnavailable = false
            return
        }
        // Stable `(UUID, owning day)` lookup; a deleted memo becomes
        // unavailable instead of resurrecting from any cache.
        if let memo = memos.first(where: { $0.id == memoID }) {
            detailMemo = memo
            detailUnavailable = false
        } else {
            detailMemo = nil
            detailUnavailable = true
        }
    }

    // MARK: Formatting

    private static func naturalDate(forDayKey dayKey: String) -> String {
        guard let date = RawStorage.date(forDayString: dayKey) else { return dayKey }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
