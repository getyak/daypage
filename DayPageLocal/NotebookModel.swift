import DayPageCore
import Foundation
import SwiftUI

@MainActor
final class NotebookModel: ObservableObject {
  @Published private(set) var entries: [NotebookEntry] = []
  @Published private(set) var configuration: AIConfiguration
  @Published var draft = ""
  @Published var error: String?
  @Published var loadIssue: String?
  @Published private(set) var isLoading = true
  @Published private(set) var isImporting = false
  let root: URL
  let store: NotebookStore
  let conversations: ConversationStore
  let preferences: UserDefaults
  private var loaded = false
  private var draftRevision: UInt64 = 0
  static let connectionKey = "local.ai.connection"

  init() {
    let preferences: UserDefaults
    if Self.isQA {
      guard let isolated = UserDefaults(suiteName: "com.daypage.qa.GET326") else {
        preconditionFailure("Cannot isolate QA preferences")
      }
      preferences = isolated
    } else {
      preferences = .standard
    }
    self.preferences = preferences
    let container =
      Self.isQA
      ? URL.documentsDirectory.appendingPathComponent("qa-GET-326", isDirectory: true)
      : URL.documentsDirectory
    let root = container.appendingPathComponent("vault", isDirectory: true)
    self.root = root
    #if DEBUG
      if Self.isQA, ProcessInfo.processInfo.arguments.contains("-qaResetNotebook") {
        // This argument has no effect in the real application bundle.
        // The QA app owns a separate sandbox and contains only synthetic data.
        try? FileManager.default.removeItem(at: root)
        preferences.removeObject(forKey: Self.connectionKey)
      }
    #endif
    store = NotebookStore(root: root)
    conversations = ConversationStore(root: root)
    configuration =
      preferences.data(forKey: Self.connectionKey)
      .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) } ?? AIConfiguration()
    #if DEBUG
      let args = ProcessInfo.processInfo.arguments
      if Self.isQA, let index = args.firstIndex(of: "-qaEndpoint"), args.indices.contains(index + 1)
      {
        configuration = AIConfiguration(
          baseURL: args[index + 1], model: "fixture-model", allowsLocalHTTP: true)
      }
    #endif
  }

  static var isQA: Bool {
    #if DEBUG
      return Bundle.main.bundleIdentifier == "com.daypage.app.localqa"
        && ProcessInfo.processInfo.arguments.contains("-qaNotebookSession")
    #else
      return false
    #endif
  }

  func load() async {
    guard !loaded else { return }
    loaded = true
    do {
      draft = try await conversations.loadDraft()
      #if DEBUG
        if Self.isQA, ProcessInfo.processInfo.arguments.contains("-qaSeedNotebook"),
          try await store.entries().isEmpty
        {
          for text in ["走回家的时候没有戴耳机，才发现这条路比想象中安静。", "把想法先留下来，未必今天就要找到答案。", "周末想留半天，把书桌旁的植物重新摆一摆。"] {
            try await store.append(Memo(body: text))
          }
        }
      #endif
    } catch { report(error) }
    await refresh()
    isLoading = false
  }

  func refresh() async {
    do {
      entries = try await store.entries()
      loadIssue = nil
    } catch {
      loadIssue = String(
        localized:
          "Your original files are safe, but this notebook could not be read. Open Files to check the Vault, or try again."
      )
      report(error)
    }
  }

  func saveDraft() {
    draftRevision += 1
    let revision = draftRevision
    let text = draft
    Task {
      do { try await conversations.saveDraft(text, revision: revision) } catch { report(error) }
    }
  }

  func save(body: String, editing entry: NotebookEntry?) async -> Bool {
    do {
      if let entry {
        try await store.update(entry, body: body)
      } else {
        try await store.append(Memo(body: body))
      }
      if entry == nil {
        draft = ""
        saveDraft()
      }
      await refresh()
      return true
    } catch {
      report(error)
      return false
    }
  }

  func importVault(_ url: URL) async {
    guard !isImporting else { return }
    isImporting = true
    defer { isImporting = false }
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
      try await store.importVault(from: url)
      await refresh()
    } catch { report(error) }
  }

  func saveConnection(_ proposed: AIConfiguration, key: String) throws {
    var config = proposed
    config.usesAPIKey = !key.isEmpty
    let origin = try config.origin
    _ = try config.endpoint
    let encoded = try JSONEncoder().encode(config)
    if config.usesAPIKey || (configuration.usesAPIKey && (try? configuration.origin) == origin) {
      try KeychainSecretStore.save(key, origin: origin)
    }
    preferences.set(encoded, forKey: Self.connectionKey)
    configuration = config
  }

  func report(_ error: Error) {
    if error is NotebookError || error is AIError || error is KeychainSecretStore.Failure {
      self.error = NSLocalizedString(error.localizedDescription, comment: "Local notebook error")
    } else if error is CancellationError {
      self.error = String(localized: "Request cancelled. Your question has been kept.")
    } else {
      self.error = String(
        localized:
          "The operation could not finish. Your original files have not been changed. Please try again."
      )
    }
  }
}
