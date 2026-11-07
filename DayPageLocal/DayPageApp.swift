import SwiftUI

@main
struct DayPageApp: App {
  @StateObject private var notebook: NotebookModel
  @StateObject private var cloud: CloudContinuity
  @StateObject private var watch: WatchPhoneBridge
  @Environment(\.scenePhase) private var phase

  init() {
    let model = NotebookModel()
    _notebook = StateObject(wrappedValue: model)
    _cloud = StateObject(wrappedValue: CloudContinuity(store: model.store, root: model.root,
      defaults: model.preferences, isQA: NotebookModel.isQA))
    let bridge = WatchPhoneBridge(store: model.store, root: model.root,
      defaults: model.preferences, disabled: NotebookModel.isQA)
    // Register before a scene or full notebook load; Watch delivery can cold-launch the app.
    bridge.activateSession()
    _watch = StateObject(wrappedValue: bridge)
  }

  var body: some Scene {
    WindowGroup {
      ScreenshotInboxView { NotebookView() }
        .environmentObject(notebook)
        .environmentObject(cloud)
        .environmentObject(watch)
        .defaultAppStorage(notebook.preferences)
        .tint(NotebookTheme.accent)
        .task {
          cloud.didChange = { await notebook.refresh() }
          watch.didChange = { await notebook.refresh() }
          await notebook.load()
          async let watchStart: Void = watch.start()
          async let cloudStart: Void = cloud.start()
          _ = await (watchStart, cloudStart)
        }
        .onChange(of: notebook.entries) { _ in cloud.schedule() }
        .onChange(of: phase) { value in
          if value == .active { Task { await cloud.start(); cloud.schedule(); await watch.resume() } }
        }
    }
  }
}
