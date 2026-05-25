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
enum SentryReporter {

    /// Skips breadcrumb dispatch when the SDK was never started. Cheap O(1)
    /// string check — no Sentry runtime call is made in the disabled path.
    static var isSentryEnabled: Bool {
        !Secrets.sentryDSN.isEmpty
    }

    /// Convenience wrapper: build a `Breadcrumb` and forward it to Sentry only
    /// when the SDK is enabled. Mirrors the existing `Breadcrumb()` +
    /// `category` + `message` + `level` pattern used at every call site.
    static func breadcrumb(category: String,
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
    static func add(_ crumb: Breadcrumb) {
        guard isSentryEnabled else { return }
        SentrySDK.addBreadcrumb(crumb)
    }
}
