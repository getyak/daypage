import SwiftUI
import DayPageStorage
import DayPageServices

// MARK: - DayPageMacApp

/// macOS entry point. Mirrors the iOS `DayPageApp` init sequence so all
/// DayPageKit hooks fire before any Kit code runs, but uses macOS-native
/// containers (WindowGroup) instead of iOS scene plumbing.
@main
struct DayPageMacApp: App {

    init() {
        // === DayPageKit hook registration (M1) ===
        // Identical contract to DayPageApp.init on iOS; without these, Storage
        // / Services Kit code falls back to the Noop adapters and degrades to
        // "everything is empty / disabled" instead of crashing — but iCloud /
        // breadcrumb diagnostics are then absent.
        SentryReporter.adapter = MacSentryAdapter()
        KitSecrets.register(MacKitSecretsProvider())
        VaultMigrationHook.register {
            // macOS does not run the iOS VaultMigrationService (different
            // iCloud entitlement model). M1 leaves migration as a no-op;
            // future M5 macOS-native migration plugs in here.
        }
        InflightDraftRefsHook.register {
            // macOS does not yet have an InflightDraftStore. Returning empty
            // means OrphanedScanner may GC an inflight attachment, but the
            // macOS Today view does not stage attachments yet (M1 is text-only).
            []
        }

        // Initialise vault directory tree on first launch (same call iOS makes).
        VaultInitializer.initializeIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
