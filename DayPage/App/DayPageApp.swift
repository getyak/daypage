import SwiftUI

@main
struct DayPageApp: App {

    init() {
        VaultInitializer.initializeIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
