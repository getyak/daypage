import SwiftUI

@main
struct DayPageApp: App {
  @StateObject private var notebook = NotebookModel()

  var body: some Scene {
    WindowGroup {
      NotebookView()
        .environmentObject(notebook)
        .defaultAppStorage(notebook.preferences)
        .tint(NotebookTheme.accent)
        .task { await notebook.load() }
    }
  }
}
