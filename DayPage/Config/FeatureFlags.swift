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

/// All known runtime flags. Add new cases here — `CaseIterable` drives the
/// Settings → Experiments list automatically.
enum FeatureFlag: String, CaseIterable {
    case backlinks
    case compileNotification
    case widgetSystemMedium
    case aiKeyBanner
    case foregroundCompileRetry
    // R5 — Round 5: kill switch for the offline-memo sync queue + Today banner.
    // Default-on; flipping to false hides the banner and skips enqueueing if
    // the underlying network layer ever starts misbehaving on a TestFlight
    // build. The queue itself stays installed but inert.
    case offlineQueue
    // R6 — 时光胶囊：kill switch for the "On This Day" memory card surfaced
    // in TodayView's zero-memo fallback. Default-on; flipping false hides
    // the card entirely (the index/scheduler stay installed but inert) so
    // a misbehaving candidate selector can be killed from Settings →
    // Experiments without a hot-fix build.
    case onThisDay

    /// Default state when the user has never touched the toggle. All Round 4
    /// flags default-on so the app behaves the way the user already expects
    /// after upgrading — Experiments only lets them *opt out*.
    var defaultEnabled: Bool {
        switch self {
        case .backlinks,
             .compileNotification,
             .widgetSystemMedium,
             .aiKeyBanner,
             .foregroundCompileRetry,
             .offlineQueue,
             .onThisDay:
            return true
        }
    }

    /// Display name in Settings → Experiments. Not localized yet — flags are
    /// power-user surface; if any flag survives to GA it should graduate out
    /// of Experiments and grow proper i18n.
    var title: String {
        switch self {
        case .backlinks:              return "实体反向链接"
        case .compileNotification:    return "编译完成通知"
        case .widgetSystemMedium:     return "Widget 中等尺寸"
        case .aiKeyBanner:            return "AI 密钥提示"
        case .foregroundCompileRetry: return "前台自动重试编译"
        case .offlineQueue:           return "离线同步队列"
        case .onThisDay:              return "时光胶囊"
        }
    }
}

/// Process-wide @MainActor singleton — flags drive SwiftUI, so reads/writes
/// must happen on the main actor. The store reads UserDefaults eagerly at
/// init() so we don't pay a defaults lookup on every `isEnabled` call.
@MainActor
final class FeatureFlagStore: ObservableObject {
    static let shared = FeatureFlagStore()

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

    func isEnabled(_ flag: FeatureFlag) -> Bool {
        overrides[flag.rawValue] ?? flag.defaultEnabled
    }

    func set(_ flag: FeatureFlag, enabled: Bool) {
        overrides[flag.rawValue] = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey(for: flag))
    }

    /// UserDefaults key. Prefixed so we can grep / purge them in one shot
    /// (e.g. settings.data.purge_all wipes "ff.*" along with everything else).
    private static func defaultsKey(for flag: FeatureFlag) -> String {
        "ff.\(flag.rawValue)"
    }
}
