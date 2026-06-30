import Foundation
import SwiftUI
import DayPageStorage

// MARK: - ThemeMode

public enum ThemeMode: String, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var label: String {
        switch self {
        case .system: return NSLocalizedString("settings.appearance.theme.system", comment: "ThemeMode label: follow system")
        case .light: return NSLocalizedString("settings.appearance.theme.light", comment: "ThemeMode label: light")
        case .dark: return NSLocalizedString("settings.appearance.theme.dark", comment: "ThemeMode label: dark")
        }
    }
}

// MARK: - AccentColorOption

public enum AccentColorOption: String, CaseIterable {
    case amber = "amber"
    case sage = "sage"
    case slate = "slate"
    case rose = "rose"
    case ink = "ink"

    public var label: String {
        switch self {
        case .amber: return NSLocalizedString("settings.appearance.accent.amber", comment: "AccentColorOption label: amber")
        case .sage: return NSLocalizedString("settings.appearance.accent.sage", comment: "AccentColorOption label: sage")
        case .slate: return NSLocalizedString("settings.appearance.accent.slate", comment: "AccentColorOption label: slate")
        case .rose: return NSLocalizedString("settings.appearance.accent.rose", comment: "AccentColorOption label: rose")
        case .ink: return NSLocalizedString("settings.appearance.accent.ink", comment: "AccentColorOption label: ink")
        }
    }

    public var color: Color {
        switch self {
        case .amber: return Color(hex: "5D3000")
        case .sage: return Color(hex: "4A6B4A")
        case .slate: return Color(hex: "4A5568")
        case .rose: return Color(hex: "9B4D6B")
        case .ink: return Color(hex: "2D2D2D")
        }
    }

    public var softColor: Color {
        switch self {
        case .amber: return Color(hex: "F5EDE3")
        case .sage: return Color(hex: "E8F0E8")
        case .slate: return Color(hex: "E8ECF0")
        case .rose: return Color(hex: "F5E8EE")
        case .ink: return Color(hex: "EAEAEA")
        }
    }
}

// MARK: - FontSizeAdjust

public enum FontSizeAdjust: String, CaseIterable {
    case small = "-1"
    case normal = "0"
    case large = "1"

    public var label: String {
        switch self {
        case .small: return NSLocalizedString("settings.appearance.fontsize.small", comment: "FontSizeAdjust label: small")
        case .normal: return NSLocalizedString("settings.appearance.fontsize.normal", comment: "FontSizeAdjust label: default")
        case .large: return NSLocalizedString("settings.appearance.fontsize.large", comment: "FontSizeAdjust label: large")
        }
    }

    /// Points to add to the base body font size (14pt).
    public var delta: CGFloat {
        switch self {
        case .small: return -1
        case .normal: return 0
        case .large: return 1
        }
    }
}

// MARK: - CardDensity

public enum CardDensity: String, CaseIterable {
    case comfortable = "comfortable"
    case compact = "compact"

    public var label: String {
        switch self {
        case .comfortable: return NSLocalizedString("settings.appearance.density.comfortable", comment: "CardDensity label: comfortable")
        case .compact: return NSLocalizedString("settings.appearance.density.compact", comment: "CardDensity label: compact")
        }
    }

    /// Points to add to a body line's base `lineSpacing`. Compact tightens the
    /// vertical rhythm of body text; comfortable keeps the design-system default.
    /// Consumed by `BodyMDModifier` / `BodySMModifier` so the setting has a
    /// visible effect (previously it was stored but never read anywhere).
    public var lineSpacingDelta: CGFloat {
        switch self {
        case .comfortable: return 0
        case .compact: return -2
        }
    }
}

// VaultLocation + AttachmentPolicy are defined in DayPageStorage/StorageSettings.swift.
// AppSettings sits in DayPageServices and re-exports nothing — call sites use
// the Storage definitions directly via `import DayPageStorage`.

// MARK: - AppSettings

/// 基于 UserDefaults 的持久化用户偏好设置。
/// 使用 AppSettings.shared 作为所有影响日期/时间计算的
/// 用户可配置选项的唯一数据源。
// MARK: - AppSettings.Keys

public extension AppSettings {
    // C4 fix: master AI toggle. Defaults to true; flipping to false in Settings
    // makes CompilationService / VoiceService refuse outbound LLM calls even
    // when API keys remain configured. Read at every call site rather than
    // cached so a toggle in Settings takes effect on the next request.
    public nonisolated static var aiFeaturesEnabled: Bool {
        let store = UserDefaults.standard
        if store.object(forKey: Keys.aiFeaturesEnabled) == nil { return true }
        return store.bool(forKey: Keys.aiFeaturesEnabled)
    }

    /// Centralized UserDefaults key constants. Use these instead of bare string
    /// literals so typos produce a compile error rather than a silent data loss.
    public enum Keys {
        // Onboarding / auth
        public static let hasOnboarded       = "hasOnboarded"
        public static let authSkipped        = "authSkipped"
        // Issue #25: timestamp the user accepted the data-flow disclosure
        // (the onboarding page that lists every outbound third-party call).
        // 0 / unset → user has never seen the disclosure.
        public static let dataFlowDisclosureAcceptedAt = "dataFlowDisclosureAcceptedAt"
        // Engagement / prompts
        public static let memoSaveCount      = "memoSaveCount"
        public static let lastSyncBannerDate = "lastSyncBannerDate"
        public static let onThisDayDismissed = "onThisDayDismissedDate"
        // Runtime API keys — US-002: migrated to Keychain (com.daypage.apikeys).
        // These string literals are kept only for the one-time UserDefaults → Keychain migration
        // performed by KeychainHelper.migrateAPIKeysFromUserDefaultsIfNeeded() at launch.
        public static let runtimeDeepSeekKey    = "runtimeDeepSeekKey"
        public static let runtimeOpenAIKey      = "runtimeOpenAIKey"
        public static let runtimeOpenWeatherKey = "runtimeOpenWeatherKey"
        // Settings — time zone, vault, attachment
        public static let preferredTimeZone  = "preferredTimeZone"
        public static let vaultLocation      = "vaultLocation"
        public static let attachmentPolicy   = "attachmentPolicy"
        // GitHub feedback repo
        public static let githubRepoOwner    = "githubRepoOwner"
        public static let githubRepoName     = "githubRepoName"
        // Migration
        public static let migrationCompletedAt = "migrationCompletedAt"
        // Appearance
        public static let themeMode          = "themeMode"
        public static let accentColor        = "accentColor"
        public static let fontSizeAdjust     = "fontSizeAdjust"
        public static let cardDensity        = "cardDensity"
        // Input
        public static let usePressToTalk     = "usePressToTalk"
        // C4 fix: master switch for any third-party AI / cloud call (compile,
        // transcribe). Default true once the user has accepted the data-flow
        // disclosure. Setting this false puts the app in "local only" mode
        // even when API keys are still configured.
        public static let aiFeaturesEnabled  = "aiFeaturesEnabled"
        // Swipe-hint nudge — shown once when the first compiled Daily Page appears
        public static let dailyPageSwipeHintShown = "today.dailyPageSwipeHintShown"
        // WriteSheet rail hint — shown once to explain media is attached via the dock
        public static let writeSheetRailHintShown = "today.writeSheetRailHintShown"
        // Swipe-hint nudge — shown once on the newest memo card to teach left/right swipe actions
        public static let memoSwipeHintShown = "memoswipeHintShown"
        // Streak milestone celebrations — comma-joined Int set, e.g. "3,7,14"
        public static let streakMilestonesShown = "streakMilestonesShown"
        // Export long-press hint — shown once when the button first appears with >=1 memo
        public static let exportLongPressHintShown = "today.exportLongPressHintShown"
        // Graph legend — comma-joined hidden entity types, e.g. "places,people"
        public static let graphHiddenTypes = "graph.hiddenTypes"
        // Summary copy hint — shown once when a compiled summary first appears
        public static let summaryCopyHintShown = "today.summaryCopyHintShown"
        // Issue #20 — 2am 编译完成本地通知：用户开关 (true → 发通知；false → 不发)。
        // 默认 true：编译完成时弹本地通知；用户在 Settings 里可关闭。
        public static let notifyCompile = "settings.notifyCompile"
        // Issue #20 — 是否已经请求过通知权限（避免冷启动重复弹系统权限弹窗，
        // Onboarding 已请求时也走这条 guard）。
        public static let hasRequestedNotifications = "settings.hasRequestedNotifications"
        // R8 debug — when true, NetworkMonitor reports isOnline=false
        // regardless of the real NWPathMonitor state. Lets the user
        // dogfood the offline SyncQueue banner without putting the
        // device into airplane mode. Default false.
        public static let debugSimulateOffline = "debug.simulateOffline"
    }
}

// MARK: - AppSettings

@MainActor
public final class AppSettings: ObservableObject {

    public static let shared = AppSettings()
    private init() {}

    // MARK: - Preferred Time Zone

    /// 用于所有日期计算的时区：文件命名、编译调度和日报归属。
    /// 默认为设备时区。
    public var preferredTimeZone: TimeZone {
        get {
            guard let id = UserDefaults.standard.string(forKey: Keys.preferredTimeZone),
                  let tz = TimeZone(identifier: id) else {
                return TimeZone.current
            }
            return tz
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.identifier, forKey: Keys.preferredTimeZone)
        }
    }

    /// 将首选时区重置为当前设备时区。
    public func resetToDeviceTimeZone() {
        UserDefaults.standard.removeObject(forKey: Keys.preferredTimeZone)
        objectWillChange.send()
    }

    // MARK: - Vault Location

    /// vault 存储位置。默认为 .local。
    public var vaultLocation: VaultLocation {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.vaultLocation),
                  let loc = VaultLocation(rawValue: raw) else {
                return .local
            }
            return loc
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.vaultLocation)
        }
    }

    // MARK: - Attachment Policy

    /// iCloud 附件的下载方式。默认为 .onDemand。
    public var attachmentPolicy: AttachmentPolicy {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.attachmentPolicy),
                  let policy = AttachmentPolicy(rawValue: raw) else {
                return .onDemand
            }
            return policy
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.attachmentPolicy)
        }
    }

    // MARK: - GitHub Repo Config

    /// The GitHub repo owner for feedback issue creation. Defaults to "cubxxw".
    public var githubRepoOwner: String {
        get {
            UserDefaults.standard.string(forKey: Keys.githubRepoOwner) ?? "cubxxw"
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Keys.githubRepoOwner)
        }
    }

    /// The GitHub repo name for feedback issue creation. Defaults to "daypage".
    public var githubRepoName: String {
        get {
            UserDefaults.standard.string(forKey: Keys.githubRepoName) ?? "daypage"
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Keys.githubRepoName)
        }
    }

    // MARK: - Theme Mode

    public var themeMode: ThemeMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.themeMode),
                  let mode = ThemeMode(rawValue: raw) else { return .system }
            return mode
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.themeMode)
        }
    }

    // MARK: - Accent Color

    public var accentColor: AccentColorOption {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.accentColor),
                  let color = AccentColorOption(rawValue: raw) else { return .amber }
            return color
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.accentColor)
        }
    }

    // MARK: - Font Size Adjust

    public var fontSizeAdjust: FontSizeAdjust {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.fontSizeAdjust),
                  let adjust = FontSizeAdjust(rawValue: raw) else { return .normal }
            return adjust
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.fontSizeAdjust)
        }
    }

    // MARK: - Card Density

    public var cardDensity: CardDensity {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.cardDensity),
                  let density = CardDensity(rawValue: raw) else { return .comfortable }
            return density
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.cardDensity)
        }
    }

    // MARK: - Migration Completed At

    /// 迁移到 iCloud 的完成日期。未迁移时为 nil。
    public var migrationCompletedAt: Date? {
        get {
            UserDefaults.standard.object(forKey: Keys.migrationCompletedAt) as? Date
        }
        set {
            objectWillChange.send()
            if let date = newValue {
                UserDefaults.standard.set(date, forKey: Keys.migrationCompletedAt)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.migrationCompletedAt)
            }
        }
    }

    // MARK: - Synchronous accessor (safe from any context)

    /// 直接从 UserDefaults 读取首选时区，无需 @MainActor 上下文。
    /// 在同步、非隔离的代码路径中使用此方法（例如 RawStorage、静态格式化器）。
    public nonisolated static func currentTimeZone() -> TimeZone {
        guard let id = UserDefaults.standard.string(forKey: Keys.preferredTimeZone),
              let tz = TimeZone(identifier: id) else {
            return TimeZone.current
        }
        return tz
    }

    /// 直接从 UserDefaults 读取附件策略，无需 @MainActor 上下文。
    /// 在 VaultInitializer 或其他非隔离代码中使用。
    public nonisolated static func currentAttachmentPolicy() -> AttachmentPolicy {
        guard let raw = UserDefaults.standard.string(forKey: Keys.attachmentPolicy),
              let policy = AttachmentPolicy(rawValue: raw) else {
            return .onDemand
        }
        return policy
    }

    /// 直接从 UserDefaults 读取 vault 位置，无需 @MainActor 上下文。
    /// 在 VaultInitializer 或其他非隔离代码中使用。
    public nonisolated static func currentVaultLocation() -> VaultLocation {
        guard let raw = UserDefaults.standard.string(forKey: Keys.vaultLocation),
              let loc = VaultLocation(rawValue: raw) else {
            return .local
        }
        return loc
    }
}

// MARK: - Color(hex:) shim

// Mirrors DesignSystem/Colors.swift's `init(hex:)`. Inlined here so AppSettings
// (which has lived in DayPageServices since M0) does not have to reverse-depend
// on the app target's DesignSystem layer. Stays `internal` to keep the public
// Color API surface unchanged.
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
