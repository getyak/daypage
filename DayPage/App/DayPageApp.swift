import SwiftUI

@main
struct DayPageApp: App {

    init() {
        DSFonts.registerAll()
        VaultInitializer.initializeIfNeeded()
        // Register background task handler before SwiftUI renders
        BackgroundCompilationService.shared.registerTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear {
                    // Schedule nightly auto-compile and backfill any missed day
                    BackgroundCompilationService.shared.scheduleIfNeeded()
                    BackgroundCompilationService.shared.backfillIfNeeded()
                }
        }
    }
}
