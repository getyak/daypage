import SwiftUI

@main
struct DayPageApp: App {

    init() {
        DSFonts.registerAll()
        VaultInitializer.initializeIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
