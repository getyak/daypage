import SwiftUI
import DayPageStorage
import DayPageServices

// MARK: - AccountSheet

/// The single account entry point for both local-only and authenticated users.
///
/// Keeping both states in one surface fixes the old dead-end where tapping the
/// sidebar profile while signed out opened an "account list" containing a dash,
/// a no-op "add account" row, and a sign-out button. Account switching is not
/// implied until the Vault-binding rules can support it safely.
struct AccountSheet: View {

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @StateObject private var syncQueue = SyncQueueService.shared
    @State private var destination: AccountDestination?
    @State private var activeAction: AccountAction?
    @State private var showSignOutConfirmation = false
    @State private var actionError: String?
    @State private var selectedDetent: PresentationDetent = .medium

    var body: some View {
        ZStack {
            DSColor.bgWarm.ignoresSafeArea()
            GrainOverlay()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: DSSpacing.sectionGap) {
                    sheetHeader
                    statusHero

                    if let actionError {
                        errorBanner(actionError)
                    }

                    if authService.session == nil {
                        signedOutContent
                    } else {
                        signedInContent
                    }
                }
                .padding(.horizontal, DSSpacing.pageMargin)
                .padding(.top, DSSpacing.sm)
                .padding(.bottom, 40)
            }
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .sheet(item: $destination) { destination in
            switch destination {
            case .emailSignIn:
                EmailAuthView()
                    .environmentObject(authService)
            }
        }
        .confirmationDialog(
            "退出此设备？",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) {
                Task { await signOutThisDevice() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机的 DayPage 会回到仅本地模式；其他设备保持登录，本地记录不会被删除。")
        }
        .onChange(of: authService.session != nil) { isSignedIn in
            if isSignedIn {
                actionError = nil
                activeAction = nil
            }
        }
        .onAppear { updatePreferredDetent() }
        .onChange(of: dynamicTypeSize) { _ in updatePreferredDetent() }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: DSSpacing.md) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("DAYPAGE · ACCOUNT")
                    .font(DSType.mono10)
                    .dynamicTypeSize(.xSmall ... .accessibility1)
                    .tracking(1.8)
                    .foregroundColor(DSColor.inkMuted)

                Text(authService.session == nil ? "让记录跟着你" : "账户与同步")
                    // Display copy keeps a modest cap so accessibility sizes
                    // reveal the account actions instead of consuming the
                    // entire first viewport. Running copy remains uncapped.
                    .font(DSType.serifDisplay28)
                    .foregroundColor(DSColor.inkPrimary)
            }

            Spacer(minLength: DSSpacing.sm)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DSColor.inkPrimary)
                    .frame(width: 44, height: 44)
                    .background(DSColor.surfaceSunken, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭账户中心")
        }
    }

    // MARK: - Status hero

    private var statusHero: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    identityMark
                    statusCopy
                }
            } else {
                HStack(spacing: DSSpacing.lg) {
                    identityMark
                    statusCopy
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(DSSpacing.cardInner)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous)
                .fill(DSColor.surfaceWhite)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.xl, style: .continuous)
                .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
        )
    }

    private var identityMark: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [DSColor.amberSoft, DSColor.amberDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 58, height: 58)

            if let initial = accountEmail.first {
                Text(String(initial).uppercased())
                    .font(DSFonts.serif(
                        size: 24,
                        weight: .semibold,
                        relativeTo: .title2,
                        maxSize: 28
                    ))
                    .foregroundColor(DSColor.onAmber)
            } else {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(DSColor.onAmber)
                    .accessibilityHidden(true)
            }
        }
    }

    private var statusCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(accountTitle)
                .font(DSFonts.serif(
                    size: 20,
                    weight: .semibold,
                    relativeTo: .title3,
                    maxSize: 30
                ))
                .foregroundColor(DSColor.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Label(syncStatus.title, systemImage: syncStatus.symbol)
                .font(DSType.bodySM)
                .foregroundColor(syncStatus.color)
                .fixedSize(horizontal: false, vertical: true)

            Text(syncStatus.detail)
                .font(DSType.labelSM)
                .foregroundColor(DSColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Signed out

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("登录后自动开启")
                .font(DSType.mono10)
                .tracking(1.5)
                .foregroundColor(DSColor.inkMuted)

            VStack(alignment: .leading, spacing: DSSpacing.md) {
                benefitRow(symbol: "arrow.triangle.2.circlepath", text: "同一账户在 iPhone、Mac 与 Web 间同步")
                benefitRow(symbol: "externaldrive.badge.icloud", text: "仍然先写入本机，离线时也不会丢失")
                benefitRow(symbol: "point.3.connected.trianglepath.dotted", text: "通过授权的 MCP 安全访问你的记录")
            }

            VStack(spacing: DSSpacing.md) {
                Button {
                    Task { await signInWithApple() }
                } label: {
                    primaryActionLabel(
                        title: "使用 Apple 登录",
                        symbol: "apple.logo",
                        isLoading: activeAction == .appleSignIn
                    )
                }
                .buttonStyle(AccountCenterPressStyle())
                .disabled(activeAction != nil || authService.isPlaceholder)
                .accessibilityHint("使用 Apple ID 登录并开启跨设备同步")

                Button {
                    destination = .emailSignIn
                } label: {
                    secondaryActionLabel(title: NSLocalizedString("account.email.signin", comment: ""), symbol: "envelope")
                }
                .buttonStyle(AccountCenterPressStyle())
                .disabled(activeAction != nil || authService.isPlaceholder)
                .accessibilityHint(NSLocalizedString("a11y.continue_email.hint", comment: ""))
            }

            if authService.isPlaceholder {
                errorBanner("当前构建尚未配置 Supabase；你仍可继续使用本地记录。")
            } else {
                Text("登录不是使用 DayPage 的前置条件。未登录时，记录只保存在这台设备的 Vault 中。")
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func benefitRow(symbol: String, text: String) -> some View {
        Label {
            Text(text)
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DSColor.accentOnBg)
                .frame(width: 24)
        }
    }

    // MARK: - Signed in

    private var signedInContent: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sectionGap) {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                Text("当前身份")
                    .font(DSType.mono10)
                    .tracking(1.5)
                    .foregroundColor(DSColor.inkMuted)

                accountDetailRow(
                    symbol: loginProviderSymbol,
                    title: accountEmail,
                    detail: loginProviderLabel
                )
                accountDetailRow(
                    symbol: "lock.shield",
                    title: "此设备的会话",
                    detail: "凭证保存在系统安全存储中"
                )
            }

            VStack(alignment: .leading, spacing: DSSpacing.md) {
                HStack {
                    Text("同步")
                        .font(DSType.mono10)
                        .tracking(1.5)
                        .foregroundColor(DSColor.inkMuted)
                    Spacer()
                    if accountSyncStatus.canRetry {
                        Button(NSLocalizedString("submit.error.retry", comment: "Retry sync")) {
                            syncQueue.requestFlushIfOnline(reason: .manual)
                        }
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.accentOnBg)
                        .disabled(syncQueue.isFlushingNow || authService.isNetworkUnavailable)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("account-sync-retry")
                    }
                }

                accountDetailRow(
                    symbol: syncStatus.symbol,
                    title: syncStatus.title,
                    detail: syncStatus.detail,
                    color: syncStatus.color
                )
            }

            Divider()
                .overlay(DSColor.inkFaint)

            VStack(alignment: .leading, spacing: DSSpacing.md) {
                Button(role: .destructive) {
                    showSignOutConfirmation = true
                } label: {
                    HStack(spacing: DSSpacing.md) {
                        if activeAction == .signOut {
                            ProgressView()
                                .tint(DSColor.statusError)
                                .frame(width: 20)
                        } else {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 20)
                        }
                        Text(activeAction == .signOut ? "正在退出…" : "退出此设备")
                            .font(DSType.bodyMD)
                        Spacer()
                    }
                    .foregroundColor(DSColor.statusError)
                    .frame(minHeight: 50)
                    .padding(.horizontal, DSSpacing.lg)
                    .background(
                        DSColor.statusError.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    )
                }
                .buttonStyle(AccountCenterPressStyle())
                .disabled(activeAction != nil)

                Text("这不会删除本地 Vault，也不会让你的其他设备退出。")
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func accountDetailRow(
        symbol: String,
        title: String,
        detail: String,
        color: Color = DSColor.inkSecondary
    ) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(DSSpacing.lg)
        .background(DSColor.surfaceWhite, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func updatePreferredDetent() {
        selectedDetent = dynamicTypeSize.isAccessibilitySize ? .large : .medium
    }

    private func signInWithApple() async {
        guard activeAction == nil else { return }
        activeAction = .appleSignIn
        actionError = nil
        do {
            try await authService.signInWithApple()
        } catch let error as DPAuthError {
            actionError = error.errorDescription
        } catch {
            actionError = "Apple 登录失败，请稍后再试。"
        }
        activeAction = nil
    }

    private func signOutThisDevice() async {
        guard activeAction == nil else { return }
        activeAction = .signOut
        actionError = nil

        // Signing out returns to local-only capture; it must not immediately
        // reopen the full-screen auth gate when the session event arrives.
        UserDefaults.standard.set(true, forKey: AppSettings.Keys.authSkipped)

        do {
            try await authService.signOut()
            dismiss()
        } catch let error as DPAuthError {
            actionError = error.errorDescription
        } catch {
            actionError = "退出失败，请稍后再试。"
        }
        activeAction = nil
    }

    // MARK: - Reusable pieces

    private func primaryActionLabel(title: String, symbol: String, isLoading: Bool) -> some View {
        ZStack {
            Label(title, systemImage: symbol)
                .font(DSFonts.inter(size: 16, weight: .semibold, relativeTo: .body))
                .opacity(isLoading ? 0 : 1)

            if isLoading {
                ProgressView().tint(DSColor.onAmber)
            }
        }
        .foregroundColor(DSColor.onAmber)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(DSColor.amberDeep, in: Capsule())
        .overlay(Capsule().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
    }

    private func secondaryActionLabel(title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(DSFonts.inter(size: 16, weight: .semibold, relativeTo: .body))
            .foregroundColor(DSColor.inkPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(DSColor.surfaceWhite, in: Capsule())
            .overlay(Capsule().strokeBorder(DSColor.inkFaint, lineWidth: 1))
    }

    private func errorBanner(_ message: String) -> some View {
        Label {
            Text(message)
                .font(DSType.bodySM)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundColor(DSColor.statusError)
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DSColor.statusError.opacity(0.10),
            in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Derived presentation

    private var accountEmail: String {
        authService.session?.user.email ?? ""
    }

    private var accountTitle: String {
        guard !accountEmail.isEmpty else { return "仅本机账户" }
        return accountEmail
    }

    private var loginProviderSymbol: String {
        switch authService.loginProvider {
        case .apple: return "apple.logo"
        case .emailLink, .unknown: return "envelope"
        }
    }

    private var loginProviderLabel: String {
        switch authService.loginProvider {
        case .apple: return "通过 Apple 登录"
        case .emailLink: return NSLocalizedString("account.email.provider", comment: "")
        case .unknown: return "已通过 Supabase 验证"
        }
    }

    private var accountSyncStatus: AccountSyncStatus {
        AccountSyncStatus.resolve(
            isSignedIn: authService.session != nil,
            isOffline: authService.isNetworkUnavailable,
            isFlushing: syncQueue.isFlushingNow,
            pendingCount: syncQueue.pendingCount,
            health: syncQueue.syncHealth
        )
    }

    private var syncStatus: SyncStatusPresentation {
        switch accountSyncStatus {
        case .localOnly:
            return .init(
                symbol: "externaldrive",
                title: "只保存在这台设备",
                detail: "登录后会自动上传现有待同步记录",
                color: DSColor.inkSecondary
            )
        case .offline(let pendingCount):
            return .init(
                symbol: "wifi.slash",
                title: "当前离线",
                detail: pendingCount == 0
                    ? "恢复网络后会自动检查其他设备的更新"
                    : "本机已保存 · \(pendingCount) 条等待同步",
                color: DSColor.statusWarning
            )
        case .syncing:
            return .init(
                symbol: "arrow.triangle.2.circlepath",
                title: "正在同步",
                detail: "正在安全上传并获取其他设备的更新",
                color: DSColor.accentOnBg
            )
        case .failed(let failure):
            let title: String
            let detail: String
            switch failure {
            case .setup:
                title = NSLocalizedString("account.sync.setup.title", comment: "Account sync setup failed")
                detail = NSLocalizedString("account.sync.setup.detail", comment: "Account binding needs attention")
            case .pull:
                title = NSLocalizedString("account.sync.failed.title", comment: "Sync failed")
                detail = NSLocalizedString("account.sync.failed.pull_detail", comment: "Remote changes could not be pulled")
            case .other:
                title = NSLocalizedString("account.sync.failed.title", comment: "Sync failed")
                detail = NSLocalizedString("account.sync.failed.detail", comment: "Sync can be retried")
            }
            return .init(
                symbol: "exclamationmark.icloud",
                title: title,
                detail: detail,
                color: DSColor.statusWarning
            )
        case .pending(let count):
            return .init(
                symbol: "icloud.and.arrow.up",
                title: "\(count) 条等待同步",
                detail: "内容已经保存在本机，可安全关闭此页面",
                color: DSColor.statusWarning
            )
        case .unverified:
            return .init(
                symbol: "icloud",
                title: NSLocalizedString("account.sync.unverified.title", comment: "Sync has not been verified yet"),
                detail: NSLocalizedString("account.sync.unverified.detail", comment: "Waiting for a complete sync check"),
                color: DSColor.inkSecondary
            )
        case .synced:
            // #884 — “已同步” is claimable ONLY from the shared completion
            // proof (current generation, memo drained, metadata current,
            // outbox 0, verified media 0). Anything else is unverified.
            guard syncQueue.completion.isFullySynced else {
                return .init(
                    symbol: "icloud",
                    title: NSLocalizedString("account.sync.unverified.title", comment: "Sync has not been verified yet"),
                    detail: NSLocalizedString("account.sync.unverified.detail", comment: "Waiting for a complete sync check"),
                    color: DSColor.inkSecondary
                )
            }
            return .init(
                symbol: "checkmark.icloud",
                title: "已同步",
                detail: "这个账户的设备会自动接收新记录",
                color: DSColor.statusSuccess
            )
        }
    }
}

// MARK: - Supporting types

private enum AccountDestination: String, Identifiable {
    case emailSignIn
    var id: String { rawValue }
}

private enum AccountAction: Equatable {
    case appleSignIn
    case signOut
}

private struct SyncStatusPresentation {
    let symbol: String
    let title: String
    let detail: String
    let color: Color
}

private struct AccountCenterPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
    }
}
