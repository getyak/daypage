import Foundation
import SwiftUI

// MARK: - ThemeMode

enum ThemeMode: String, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var label: String {
        switch self {
        case .system: return "系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

// MARK: - AccentColorOption

enum AccentColorOption: String, CaseIterable {
    case amber = "amber"
    case sage = "sage"
    case slate = "slate"
    case rose = "rose"
    case ink = "ink"

    var label: String {
        switch self {
        case .amber: return "琥珀"
        case .sage: return "鼠尾草"
        case .slate: return "青石"
        case .rose: return "玫瑰"
        case .ink: return "墨"
        }
    }

    var color: Color {
        switch self {
        case .amber: return Color(hex: "5D3000")
        case .sage: return Color(hex: "4A6B4A")
        case .slate: return Color(hex: "4A5568")
        case .rose: return Color(hex: "9B4D6B")
        case .ink: return Color(hex: "2D2D2D")
        }
    }

    var softColor: Color {
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

enum FontSizeAdjust: String, CaseIterable {
    case small = "-1"
    case normal = "0"
    case large = "1"

    var label: String {
        switch self {
        case .small: return "小"
        case .normal: return "默认"
        case .large: return "大"
        }
    }

    /// Points to add to the base body font size (14pt).
    var delta: CGFloat {
        switch self {
        case .small: return -1
        case .normal: return 0
        case .large: return 1
        }
    }
}

// MARK: - CardDensity

enum CardDensity: String, CaseIterable {
    case comfortable = "comfortable"
    case compact = "compact"

    var label: String {
        switch self {
        case .comfortable: return "舒适"
        case .compact: return "紧凑"
        }
    }
}

// MARK: - VaultLocation

enum VaultLocation: String {
    case local = "local"
    case iCloud = "iCloud"
}

// MARK: - AttachmentPolicy

enum AttachmentPolicy: String {
    case onDemand = "onDemand"
    case alwaysLocal = "alwaysLocal"
}

// MARK: - AppSettings

/// 基于 UserDefaults 的持久化用户偏好设置。
/// 使用 AppSettings.shared 作为所有影响日期/时间计算的
/// 用户可配置选项的唯一数据源。
// MARK: - AppSettings.Keys

extension AppSettings {
    /// Centralized UserDefaults key constants. Use these instead of bare string
    /// literals so typos produce a compile error rather than a silent data loss.
    enum Keys {
        // Onboarding / auth
        static let hasOnboarded       = "hasOnboarded"
        static let authSkipped        = "authSkipped"
        // Engagement / prompts
        static let memoSaveCount      = "memoSaveCount"
        static let lastSyncBannerDate = "lastSyncBannerDate"
        static let onThisDayDismissed = "onThisDayDismissedDate"
        // Runtime API keys (entered during onboarding, stored in UserDefaults)
        static let runtimeDeepSeekKey    = "runtimeDeepSeekKey"
        static let runtimeOpenAIKey      = "runtimeOpenAIKey"
        static let runtimeOpenWeatherKey = "runtimeOpenWeatherKey"
        // Settings — time zone, vault, attachment
        static let preferredTimeZone  = "preferredTimeZone"
        static let vaultLocation      = "vaultLocation"
        static let attachmentPolicy   = "attachmentPolicy"
        // GitHub feedback repo
        static let githubRepoOwner    = "githubRepoOwner"
        static let githubRepoName     = "githubRepoName"
        // Migration
        static let migrationCompletedAt = "migrationCompletedAt"
        // Appearance
        static let themeMode          = "themeMode"
        static let accentColor        = "accentColor"
        static let fontSizeAdjust     = "fontSizeAdjust"
        static let cardDensity        = "cardDensity"
        // Input
        static let usePressToTalk     = "usePressToTalk"
    }
}

// MARK: - AppSettings

@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()
    private init() {}

    // MARK: - Preferred Time Zone

    /// 用于所有日期计算的时区：文件命名、编译调度和日报归属。
    /// 默认为设备时区。
    var preferredTimeZone: TimeZone {
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
    func resetToDeviceTimeZone() {
        UserDefaults.standard.removeObject(forKey: Keys.preferredTimeZone)
        objectWillChange.send()
    }

    // MARK: - Vault Location

    /// vault 存储位置。默认为 .local。
    var vaultLocation: VaultLocation {
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
    var attachmentPolicy: AttachmentPolicy {
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
    var githubRepoOwner: String {
        get {
            UserDefaults.standard.string(forKey: Keys.githubRepoOwner) ?? "cubxxw"
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Keys.githubRepoOwner)
        }
    }

    /// The GitHub repo name for feedback issue creation. Defaults to "daypage".
    var githubRepoName: String {
        get {
            UserDefaults.standard.string(forKey: Keys.githubRepoName) ?? "daypage"
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Keys.githubRepoName)
        }
    }

    // MARK: - Theme Mode

    var themeMode: ThemeMode {
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

    var accentColor: AccentColorOption {
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

    var fontSizeAdjust: FontSizeAdjust {
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

    var cardDensity: CardDensity {
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
    var migrationCompletedAt: Date? {
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
    nonisolated static func currentTimeZone() -> TimeZone {
        guard let id = UserDefaults.standard.string(forKey: Keys.preferredTimeZone),
              let tz = TimeZone(identifier: id) else {
            return TimeZone.current
        }
        return tz
    }

    /// 直接从 UserDefaults 读取附件策略，无需 @MainActor 上下文。
    /// 在 VaultInitializer 或其他非隔离代码中使用。
    nonisolated static func currentAttachmentPolicy() -> AttachmentPolicy {
        guard let raw = UserDefaults.standard.string(forKey: Keys.attachmentPolicy),
              let policy = AttachmentPolicy(rawValue: raw) else {
            return .onDemand
        }
        return policy
    }

    /// 直接从 UserDefaults 读取 vault 位置，无需 @MainActor 上下文。
    /// 在 VaultInitializer 或其他非隔离代码中使用。
    nonisolated static func currentVaultLocation() -> VaultLocation {
        guard let raw = UserDefaults.standard.string(forKey: Keys.vaultLocation),
              let loc = VaultLocation(rawValue: raw) else {
            return .local
        }
        return loc
    }
}
