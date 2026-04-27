import Foundation

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
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()
    private init() {}

    // MARK: - Preferred Time Zone

    private let timeZoneKey = "preferredTimeZone"

    /// 用于所有日期计算的时区：文件命名、编译调度和日报归属。
    /// 默认为设备时区。
    var preferredTimeZone: TimeZone {
        get {
            guard let id = UserDefaults.standard.string(forKey: timeZoneKey),
                  let tz = TimeZone(identifier: id) else {
                return TimeZone.current
            }
            return tz
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.identifier, forKey: timeZoneKey)
        }
    }

    /// 将首选时区重置为当前设备时区。
    func resetToDeviceTimeZone() {
        UserDefaults.standard.removeObject(forKey: timeZoneKey)
        objectWillChange.send()
    }

    // MARK: - Vault Location

    static let vaultLocationKey = "vaultLocation"

    /// vault 存储位置。默认为 .local。
    var vaultLocation: VaultLocation {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.vaultLocationKey),
                  let loc = VaultLocation(rawValue: raw) else {
                return .local
            }
            return loc
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.vaultLocationKey)
        }
    }

    // MARK: - Attachment Policy

    static let attachmentPolicyKey = "attachmentPolicy"

    /// iCloud 附件的下载方式。默认为 .onDemand。
    var attachmentPolicy: AttachmentPolicy {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.attachmentPolicyKey),
                  let policy = AttachmentPolicy(rawValue: raw) else {
                return .onDemand
            }
            return policy
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.attachmentPolicyKey)
        }
    }

    // MARK: - Migration Completed At

    static let migrationCompletedAtKey = "migrationCompletedAt"

    /// 迁移到 iCloud 的完成日期。未迁移时为 nil。
    var migrationCompletedAt: Date? {
        get {
            UserDefaults.standard.object(forKey: Self.migrationCompletedAtKey) as? Date
        }
        set {
            objectWillChange.send()
            if let date = newValue {
                UserDefaults.standard.set(date, forKey: Self.migrationCompletedAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.migrationCompletedAtKey)
            }
        }
    }

    // MARK: - Synchronous accessor (safe from any context)

    /// 直接从 UserDefaults 读取首选时区，无需 @MainActor 上下文。
    /// 在同步、非隔离的代码路径中使用此方法（例如 RawStorage、静态格式化器）。
    nonisolated static func currentTimeZone() -> TimeZone {
        guard let id = UserDefaults.standard.string(forKey: "preferredTimeZone"),
              let tz = TimeZone(identifier: id) else {
            return TimeZone.current
        }
        return tz
    }

    /// 直接从 UserDefaults 读取附件策略，无需 @MainActor 上下文。
    /// 在 VaultInitializer 或其他非隔离代码中使用。
    nonisolated static func currentAttachmentPolicy() -> AttachmentPolicy {
        guard let raw = UserDefaults.standard.string(forKey: "attachmentPolicy"),
              let policy = AttachmentPolicy(rawValue: raw) else {
            return .onDemand
        }
        return policy
    }

    /// 直接从 UserDefaults 读取 vault 位置，无需 @MainActor 上下文。
    /// 在 VaultInitializer 或其他非隔离代码中使用。
    nonisolated static func currentVaultLocation() -> VaultLocation {
        guard let raw = UserDefaults.standard.string(forKey: "vaultLocation"),
              let loc = VaultLocation(rawValue: raw) else {
            return .local
        }
        return loc
    }
}
