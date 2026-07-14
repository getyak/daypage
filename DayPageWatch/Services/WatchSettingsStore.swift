import Foundation
import Combine
import AVFoundation

// MARK: - Capture Mode

/// How a recording is started and stopped on the watch. The user picks one in
/// Settings; `RecordingView` adapts its gesture handling accordingly.
///
/// - `.tap`   点击式：点开始 / 录音中点停止发送 / 长按取消（从容记录，防误触）
/// - `.press` 长按式：按住录 / 松手即发送 / 按住上滑取消（对讲机，单手快捕）
enum WatchCaptureMode: String, CaseIterable, Identifiable {
    case tap
    case press

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap:   return "点击式"
        case .press: return "长按式"
        }
    }

    var subtitle: String {
        switch self {
        case .tap:   return "点击启停 · 长按取消"
        case .press: return "按住录音 · 松手发送"
        }
    }
}

// MARK: - Audio Quality

/// Recording quality preset. Trades file size / battery against transcription
/// fidelity. Sample rate + AVAudioQuality feed straight into the recorder
/// settings in `WatchRecordingModel`.
enum WatchAudioQuality: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:    return "低"
        case .medium: return "中"
        case .high:   return "高"
        }
    }

    /// Sample rate in Hz. Voice is intelligible from 12 kHz; 24 kHz is
    /// comfortably above the Whisper sweet spot without bloating the file.
    var sampleRate: Double {
        switch self {
        case .low:    return 12_000
        case .medium: return 16_000
        case .high:   return 24_000
        }
    }

    var encoderQuality: AVAudioQuality {
        switch self {
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        }
    }
}

// MARK: - Cleanup Policy

/// How long an *undelivered* recording lingers on the watch before the orphan
/// cleaner may remove it. Delivered files are always removed immediately in
/// `session(_:didFinish:)`; this only governs in-flight / failed clips so a
/// watch that stays away from its phone doesn't silently lose a memo.
enum WatchRetentionPolicy: String, CaseIterable, Identifiable {
    case oneDay
    case sevenDays
    case untilDelivered

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneDay:         return "1 天"
        case .sevenDays:      return "7 天"
        case .untilDelivered: return "直到送达"
        }
    }

    /// Max age for an undelivered file, in seconds. `nil` means "never expire
    /// an undelivered file — keep it until it is confirmed delivered."
    var maxUndeliveredAge: TimeInterval? {
        switch self {
        case .oneDay:         return 86_400
        case .sevenDays:      return 604_800
        case .untilDelivered: return nil
        }
    }
}

// MARK: - WatchSettingsStore

/// The watch's local source of truth for capture configuration. Backed by
/// `UserDefaults` on the watch; the phone-side Watch app mirrors key items via
/// `updateApplicationContext` (wired in a later phase).
///
/// `@MainActor` because every value drives SwiftUI. Reads are served from the
/// in-memory `@Published` properties, not from `UserDefaults` on each access.
@MainActor
final class WatchSettingsStore: ObservableObject {

    static let shared = WatchSettingsStore()

    // MARK: Keys

    private enum Key {
        static let captureMode  = "watch.captureMode"
        static let maxDuration  = "watch.maxDuration"
        static let audioQuality = "watch.audioQuality"
        static let hapticsStart = "watch.haptics.start"
        static let hapticsStop  = "watch.haptics.stop"
        static let retention    = "watch.retention"
        static let wifiOnly     = "watch.wifiOnlyTransfer"
    }

    private let defaults: UserDefaults

    // MARK: Published state

    @Published var captureMode: WatchCaptureMode {
        didSet { defaults.set(captureMode.rawValue, forKey: Key.captureMode) }
    }

    /// Max recording duration in seconds. Clamped to the crown range 30…180.
    @Published var maxDuration: Int {
        didSet {
            let clamped = min(180, max(30, maxDuration))
            if clamped != maxDuration { maxDuration = clamped; return }
            defaults.set(maxDuration, forKey: Key.maxDuration)
        }
    }

    @Published var audioQuality: WatchAudioQuality {
        didSet { defaults.set(audioQuality.rawValue, forKey: Key.audioQuality) }
    }

    /// Haptic on record start.
    @Published var hapticsOnStart: Bool {
        didSet { defaults.set(hapticsOnStart, forKey: Key.hapticsStart) }
    }

    /// Haptic on record stop / send.
    @Published var hapticsOnStop: Bool {
        didSet { defaults.set(hapticsOnStop, forKey: Key.hapticsStop) }
    }

    @Published var retentionPolicy: WatchRetentionPolicy {
        didSet { defaults.set(retentionPolicy.rawValue, forKey: Key.retention) }
    }

    /// When true, only transfer files while on Wi-Fi (the phone-side transfer
    /// path honors this in a later phase). Default off — Bluetooth transfer is
    /// the whole point of the paired-device model.
    @Published var wifiOnlyTransfer: Bool {
        didSet { defaults.set(wifiOnlyTransfer, forKey: Key.wifiOnly) }
    }

    // MARK: Init

    /// `defaults` is injectable so tests get an isolated suite instead of
    /// mutating the shared `.standard` domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.captureMode = WatchCaptureMode(rawValue: defaults.string(forKey: Key.captureMode) ?? "") ?? .tap

        let storedDuration = defaults.object(forKey: Key.maxDuration) as? Int ?? 60
        self.maxDuration = min(180, max(30, storedDuration))

        self.audioQuality = WatchAudioQuality(rawValue: defaults.string(forKey: Key.audioQuality) ?? "") ?? .medium

        // Haptics default ON; `object(forKey:)` distinguishes "never set" from
        // an explicit false so a user who turned them off keeps them off.
        self.hapticsOnStart = defaults.object(forKey: Key.hapticsStart) as? Bool ?? true
        self.hapticsOnStop  = defaults.object(forKey: Key.hapticsStop) as? Bool ?? true

        self.retentionPolicy = WatchRetentionPolicy(rawValue: defaults.string(forKey: Key.retention) ?? "") ?? .sevenDays

        self.wifiOnlyTransfer = defaults.object(forKey: Key.wifiOnly) as? Bool ?? false
    }
}
