// FeatureFlags.swift — Round 4 (R4-MEDIUM #39)
//
// Lightweight, UserDefaults-backed feature-flag registry. All flags default
// to "on" so the rollout looks identical to today's app; flipping a flag in
// Settings → Experiments only turns *off* a recently-landed feature.
//
// Why this exists:
//   - Several Round 3/4 features (backlinks, compile notification, AI key
//     banner, foreground compile retry) shipped without a kill switch. If
//     any of them misbehaves in TestFlight we'd previously need a hot-fix
//     build to turn them off. This file makes them runtime-toggleable.
//   - The registry deliberately ships a tiny surface (`isEnabled` /
//     `set(_:enabled:)`) so callers don't accidentally invent ad-hoc flag
//     reads scattered across the codebase.

import Foundation
import SwiftUI
import DayPageStorage

/// All known runtime flags. Add new cases here — `CaseIterable` drives the
/// Settings → Experiments list automatically.
public enum FeatureFlag: String, CaseIterable {
    /// **Used in**: `EntityPageView.backlinksSection` (Features/Entity/EntityPageView.swift)
    /// **When off**: Entity 页隐藏 "被 N 个 memo 引用" 区块；索引仍由 EntityPageService 维护。
    /// **Default**: on
    case backlinks

    /// **Used in**: `BackgroundCompilationService.sendSuccessNotification` (Services/BackgroundCompilationService.swift)
    /// **When off**: 02:00 BGTask 编译成功后不发本地通知（编译本身仍照常执行，写入 daily 文件）。
    /// **Default**: on
    case compileNotification

    /// **Used in**: `QuickCaptureWidget.supportedFamilies` (DayPageWidget/QuickCaptureWidget.swift)
    /// **When off**: Widget 不暴露 `systemMedium` 尺寸（只保留 small / accessory）。需要用户重新添加 Widget 才会生效。
    /// **Default**: on
    case widgetSystemMedium

    /// **Used in**: `TodayView.shouldShowAIKeyBanner` (Features/Today/TodayView.swift)
    /// **When off**: AI key 缺失时不显示顶部黄色 banner；BackgroundCompilationService 仍会因缺 key 而 fail-fast。
    /// **Default**: on
    case aiKeyBanner

    /// **Used in**: `DayPageApp.body` 的 `scenePhase == .active` 分支（App/DayPageApp.swift）
    /// **When off**: 回前台不调 `BackgroundCompilationService.foregroundRetryIfNeeded`；仅 02:00 BGTask 触发编译。
    /// **Default**: on
    case foregroundCompileRetry

    /// **Used in**: `TodayView.syncQueuePendingBanner` + `syncStatusCount` (Features/Today/TodayView.swift)
    /// **When off**: Today 顶部 SyncQueue banner 不显示；RawStorage 仍照常 enqueue，队列继续累积（仅 UI 屏蔽）。
    /// **R5**: 离线同步队列 kill switch — 给 TestFlight 网络层异常一个无需 hot-fix 的兜底开关。
    /// **Default**: on
    case offlineQueue

    /// **Used in**: `TodayView.shouldShowOnThisDayAtTop` + `onThisDayFallback` (Features/Today/TodayView.swift)
    /// **When off**: Today 顶部 + zero-memo fallback 内 OnThisDayCard 都不显示；索引/调度器仍 installed but inert。
    /// **R6**: 时光胶囊 — 给 candidate 选择器异常一个无需 hot-fix 的兜底开关。
    /// **Default**: on
    case onThisDay

    /// **Used in**: `ArchiveView.weeklyRecapEntryCard` (Features/Archive/ArchiveView.swift)
    /// **When off**: Archive 周入口卡不显示；后台自动编译仍会跑（service 不下线，只屏蔽 UI 入口）。
    /// **R7**: 周回顾 — 给 prompt/parse 异常一个无需 hot-fix 的兜底开关。
    /// **#814**: Today 顶部 preview 卡已移除，Archive 是唯一入口。
    /// **Default**: on
    case weeklyRecap

    /// **Used in**: `SettingsView` 数据 section (R13+) — 入口卡进入 `VaultExportView`。
    /// **When off**: 隐藏 "导出 vault" 入口；`VaultExportService` 仍存在，纯数据层；不影响 BGTask 编译 / sync。
    /// **R11**: Vault 整体导出 — 给 manifest 扫描 / zip 打包异常一个无需 hot-fix 的兜底开关。
    /// **Default**: on
    case vaultExport

    /// **Used in**: `RootView`（DayPageWatch/App/RootView.swift）
    /// **When off**: 手表回退到旧的单屏录音（只 `RecordingView`），不显示三页 TabView / 历史 / 设置。
    /// **Watch**: 手表捕获可配置化（三页导航 + 设置 + 历史）—— 给新交互一个无需 hot-fix 的兜底开关。
    /// **Default**: on
    case watchCaptureConfig

    /// Default state when the user has never touched the toggle. All Round 4
    /// flags default-on so the app behaves the way the user already expects
    /// after upgrading — Experiments only lets them *opt out*.
    public var defaultEnabled: Bool {
        switch self {
        case .backlinks,
             .compileNotification,
             .widgetSystemMedium,
             .aiKeyBanner,
             .foregroundCompileRetry,
             .offlineQueue,
             .onThisDay,
             .weeklyRecap,
             .vaultExport,
             .watchCaptureConfig:
            return true
        }
    }

    /// Display name in Settings → Experiments. Not localized yet — flags are
    /// power-user surface; if any flag survives to GA it should graduate out
    /// of Experiments and grow proper i18n.
    public var title: String {
        switch self {
        case .backlinks:              return "实体反向链接"
        case .compileNotification:    return "编译完成通知"
        case .widgetSystemMedium:     return "Widget 中等尺寸"
        case .aiKeyBanner:            return "AI 密钥提示"
        case .foregroundCompileRetry: return "前台自动重试编译"
        case .offlineQueue:           return "离线同步队列"
        case .onThisDay:              return "时光胶囊"
        case .weeklyRecap:            return "周回顾"
        case .vaultExport:            return "Vault 导出"
        case .watchCaptureConfig:     return "手表捕获配置"
        }
    }
}

/// Process-wide @MainActor singleton — flags drive SwiftUI, so reads/writes
/// must happen on the main actor. The store reads UserDefaults eagerly at
/// init() so we don't pay a defaults lookup on every `isEnabled` call.
@MainActor
public final class FeatureFlagStore: ObservableObject {
    public static let shared = FeatureFlagStore()

    /// Per-flag override map. `nil` = use `defaultEnabled`. Storing in a
    /// dict lets us serve `isEnabled` without hitting UserDefaults each time.
    @Published private var overrides: [String: Bool] = [:]

    private init() {
        for flag in FeatureFlag.allCases {
            let key = Self.defaultsKey(for: flag)
            // `object(forKey:)` returns nil when the user has never written
            // to that key; we only mirror it into `overrides` when present
            // so we cleanly fall through to `defaultEnabled` otherwise.
            if UserDefaults.standard.object(forKey: key) != nil {
                overrides[flag.rawValue] = UserDefaults.standard.bool(forKey: key)
            }
        }
    }

    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        overrides[flag.rawValue] ?? flag.defaultEnabled
    }

    public func set(_ flag: FeatureFlag, enabled: Bool) {
        overrides[flag.rawValue] = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey(for: flag))
    }

    /// UserDefaults key. Prefixed so we can grep / purge them in one shot
    /// (e.g. settings.data.purge_all wipes "ff.*" along with everything else).
    private static func defaultsKey(for flag: FeatureFlag) -> String {
        "ff.\(flag.rawValue)"
    }
}
