import Foundation
import Sentry

/// Thin wrapper around `SentrySDK.addBreadcrumb(...)` that no-ops when the SDK
/// is not started (i.e. when `Secrets.sentryDSN` is empty — typical for local
/// dev / CI builds without a configured DSN).
///
/// Why this exists: calling `SentrySDK.addBreadcrumb(...)` against a disabled
/// SDK floods the console with `[Sentry] [fatal] The SDK is disabled, so
/// addBreadcrumb doesn't work.` lines — once per call site, on every write —
/// which drowns out the actual diagnostic logs we ship breadcrumbs for.
///
/// `nonisolated` and free of any UI dependency so it can be called from any
/// thread, actor, or background queue (matching the existing breadcrumb call
/// sites in `RawStorage`, `ConflictMerger`, `DayPageLogger`, …).
public enum SentryReporter {

    /// UserDefaults key the main app target writes its Sentry DSN to at
    /// launch. DayPageStorage cannot reach the `Secrets` enum directly because
    /// that file is gitignored and lives per-target; reading the DSN out of
    /// UserDefaults keeps the breadcrumb guard portable across iOS + macOS
    /// without re-introducing a hard dependency on Secrets generation.
    /// App targets must call `SentryReporter.configure(dsn: Secrets.sentryDSN)`
    /// in `DayPageApp.init` BEFORE the first Storage write.
    public static let sentryDSNDefaultsKey = "DayPageStorage.SentryDSN"

    /// Called by app targets at launch to register the Sentry DSN with the
    /// Storage-layer breadcrumb guard. Empty string disables breadcrumbs.
    public static func configure(dsn: String) {
        UserDefaults.standard.set(dsn, forKey: sentryDSNDefaultsKey)
    }

    /// Skips breadcrumb dispatch when the SDK was never started. Cheap O(1)
    /// UserDefaults check — no Sentry runtime call is made in the disabled path.
    public static var isSentryEnabled: Bool {
        guard let dsn = UserDefaults.standard.string(forKey: sentryDSNDefaultsKey) else { return false }
        return !dsn.isEmpty
    }

    /// Convenience wrapper: build a `Breadcrumb` and forward it to Sentry only
    /// when the SDK is enabled. Mirrors the existing `Breadcrumb()` +
    /// `category` + `message` + `level` pattern used at every call site.
    public static func breadcrumb(category: String,
                           level: SentryLevel = .info,
                           message: String) {
        guard isSentryEnabled else { return }
        let crumb = Breadcrumb()
        crumb.category = category
        crumb.message = message
        crumb.level = level
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Escape hatch for the few call sites that build a pre-populated
    /// `Breadcrumb` (e.g. with extra fields like `data`/`type`). Drops the
    /// breadcrumb silently when Sentry is disabled.
    public static func add(_ crumb: Breadcrumb) {
        guard isSentryEnabled else { return }
        SentrySDK.addBreadcrumb(crumb)
    }
}
