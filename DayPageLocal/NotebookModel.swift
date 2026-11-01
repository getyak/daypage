import DayPageCore
import Foundation
import SwiftUI

@MainActor
final class NotebookModel: ObservableObject {
  @Published private(set) var entries: [NotebookEntry] = []
  @Published private(set) var catalog = NotebookCatalog(entries: [])
  @Published private(set) var lastCapturedNoteID: UUID?
  // A one-shot UI request, separate from the last capture's navigation event.
  @Published private(set) var pendingCaptureRevealID: UUID?
  @Published private(set) var configuration: AIConfiguration
  @Published var draft = ""
  @Published var error: String?
  @Published var loadIssue: String?
  @Published private(set) var pendingAssets: [PendingNoteAsset] = []
  @Published private(set) var isSaving = false
  @Published private(set) var lastDeleted: NotebookTrashReceipt?
  var canAddCaptureAsset: Bool {
    pendingAssets.count < 10 && pendingAssets.reduce(0, { $0 + $1.data.count }) < 50 * 1024 * 1024
  }
  var canRecordVoice: Bool {
    // A ten-minute 64 kbps AAC recording needs roughly 4.8 MB plus overhead.
    // Reserve space before entering a recorder that cannot remove other assets.
    pendingAssets.count < 10 && pendingAssets.reduce(0, { $0 + $1.data.count }) <= 44 * 1024 * 1024
  }
  @Published private(set) var isLoading = true
  @Published private(set) var isImporting = false
  let root: URL
  let store: NotebookStore
  let conversations: ConversationStore
  private let captureDrafts: CaptureDraftStore
  let preferences: UserDefaults
  private var loaded = false
  private var captureRevision: UInt64 = 0
  private var captureMemoID = UUID()
  private var needsDraftSave = false
  private var captureDraftReady = false
  private var changingCapture = false
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
    captureDrafts = CaptureDraftStore(root: root)
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
      var localIDs = Set(
        try await store.entries().filter { $0.namespace.isEmpty }.map { $0.memo.id })
      // A committed note can be trashed before failed draft cleanup is repaired.
      // Only validated, completed local trash receipts also consume the draft.
      localIDs.formUnion(
        try await store.trashReceipts().filter { $0.entry.namespace.isEmpty }.map {
          $0.entry.memo.id
        })
      let snapshot = try await captureDrafts.load(committedMemoIDs: localIDs)
      captureMemoID = snapshot.memoID
      captureRevision = snapshot.revision
      draft = snapshot.body
      pendingAssets = snapshot.assets
      captureDraftReady = true
      #if DEBUG
        if Self.isQA, ProcessInfo.processInfo.arguments.contains("-qaSeedCaptureDraft"),
          pendingAssets.isEmpty
        {
          await addCaptureAsset(
            data: Data("A synthetic file kept with the draft.".utf8),
            filename: "Trip checklist.txt", kind: "file")
        }
        if Self.isQA, ProcessInfo.processInfo.arguments.contains("-qaSeedCaptureQuota"),
          pendingAssets.isEmpty
        {
          for index in 0..<10 {
            await addCaptureAsset(
              data: Data("Synthetic attachment \(index)".utf8), filename: "Fixture-\(index).txt",
              kind: "file")
          }
        }
      #endif
      #if DEBUG
        if Self.isQA, ProcessInfo.processInfo.arguments.contains("-qaSeedNotebook"),
          ProcessInfo.processInfo.arguments.contains("-qaSeedLargeNotebook"),
          try await store.entries().isEmpty
        {
          let calendar = Calendar(identifier: .gregorian)
          for index in 0..<360 {
            let day = calendar.date(byAdding: .day, value: -(index / 3), to: Date()) ?? Date()
            let time = calendar.date(bySettingHour: 9 + (index % 3) * 4, minute: 10, second: 0, of: day) ?? day
            try await store.append(Memo(created: time, body: "Synthetic history \(index). A moment to revisit. #history"))
          }
        }
        if Self.isQA, ProcessInfo.processInfo.arguments.contains("-qaSeedNotebook"),
          try await store.entries().isEmpty
        {
          let samples =
            Locale.preferredLanguages.first?.hasPrefix("zh") == true
            ? [
              "回家的时候没有戴耳机。雨停了，路边的树还在滴水。\n\n今天没有想清楚所有问题，但记下来的几句话，已经让它们不再挤在脑子里。 #日常",
              "把规则当作游戏的一部分，也为自己留下一点自由。 #灵感",
              "好的工具应该允许我先留下原始的声音，等到合适的时候，再慢慢理解它。\n\n阅读也一样。短句应该一眼读完，长文应该保留段落和节奏。",
            ]
            : [
              "Walked home without headphones. The rain had stopped, but the trees were still dripping.\n\nWriting a few lines left a little more room in my head. #everyday",
              "Treat the rules as part of the game. Leave a little room for yourself, too. #ideas",
              "A good notebook leaves room for unfinished thoughts. I can make sense of them later.\n\nShort notes should feel immediate. Longer ones deserve space to breathe.",
            ]
          for (index, text) in samples.enumerated() {
            let time =
              Calendar.current.date(
                bySettingHour: 19 - index * 3, minute: 33 - index * 7, second: 0, of: Date())
              ?? Date()
            try await store.append(Memo(created: time, body: text))
          }
        }
      #endif
    } catch { report(error) }
    await refresh()
    isLoading = false
  }

  func refresh() async {
    do {
      let snapshot = try await store.entries()
      catalog = NotebookCatalog(entries: snapshot)
      entries = snapshot
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
    guard captureDraftReady else { return }
    guard !isSaving, !changingCapture else {
      needsDraftSave = true
      return
    }
    captureRevision += 1
    let revision = captureRevision
    let snapshot = CaptureDraftSnapshot(memoID: captureMemoID, body: draft, assets: pendingAssets)
    Task {
      do { try await captureDrafts.saveBody(snapshot, revision: revision) } catch { report(error) }
    }
  }

  private func flushDeferredDraft() {
    guard needsDraftSave, !isSaving, !changingCapture else { return }
    needsDraftSave = false
    saveDraft()
  }

  func save(body: String, editing entry: NotebookEntry?) async -> Bool {
    guard !isSaving, !changingCapture, entry != nil || captureDraftReady else { return false }
    isSaving = true
    let capturedID = entry == nil ? captureMemoID : nil
    defer {
      isSaving = false
      flushDeferredDraft()
    }
    do {
      if let entry {
        try await store.update(entry, body: body)
      } else {
        draft = body
        let snapshot = CaptureDraftSnapshot(
          memoID: captureMemoID, body: body, assets: pendingAssets)
        captureRevision += 1
        // Persist the identity and full draft before publishing any raw data.
        // After a crash this same ID identifies an already committed note.
        try await captureDrafts.save(snapshot, revision: captureRevision)
        try await store.append(
          Memo(id: snapshot.memoID, body: body),
          assets: snapshot.assets.map {
            NotebookAssetInput(
              data: $0.data, fileExtension: $0.fileExtension, kind: $0.kind, duration: $0.duration)
          })
      }
      if entry == nil {
        let next = CaptureDraftSnapshot()
        captureRevision += 1
        // A committed note must never be reported as a failed save merely
        // because clearing a separate draft snapshot failed.
        do {
          try await captureDrafts.save(next, revision: captureRevision)
        } catch {
          report(error)
        }
        captureMemoID = next.memoID
        draft = ""
        pendingAssets = []
        needsDraftSave = false
      }
      await refresh()
      if let capturedID {
        pendingCaptureRevealID = capturedID
        lastCapturedNoteID = capturedID
      }
      return true
    } catch {
      report(error)
      return false
    }
  }

  func acknowledgeCaptureReveal(_ id: UUID) {
    guard pendingCaptureRevealID == id else { return }
    pendingCaptureRevealID = nil
  }

  @discardableResult
  func addCaptureAsset(data: Data, filename: String, kind: String, duration: Double? = nil) async
    -> Bool
  {
    guard captureDraftReady, !isSaving, !changingCapture else { return false }
    changingCapture = true
    defer {
      changingCapture = false
      flushDeferredDraft()
    }
    let proposedExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
    let safeExtension =
      !proposedExtension.isEmpty && proposedExtension.count <= 12
        && proposedExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
      ? proposedExtension : "bin"
    let asset = PendingNoteAsset(
      data: data, name: filename,
      fileExtension: safeExtension, kind: kind, duration: duration)
    let proposed = pendingAssets + [asset]
    captureRevision += 1
    do {
      try await captureDrafts.save(
        CaptureDraftSnapshot(memoID: captureMemoID, body: draft, assets: proposed),
        revision: captureRevision)
      pendingAssets = proposed
      return true
    } catch {
      report(error)
      return false
    }
  }

  func removeCaptureAsset(_ id: UUID) async {
    guard !isSaving, !changingCapture else { return }
    changingCapture = true
    defer {
      changingCapture = false
      flushDeferredDraft()
    }
    captureRevision += 1
    let proposed = pendingAssets.filter { $0.id != id }
    do {
      try await captureDrafts.save(
        CaptureDraftSnapshot(memoID: captureMemoID, body: draft, assets: proposed),
        revision: captureRevision)
      pendingAssets = proposed
    } catch { report(error) }
  }

  func discardDraft() async {
    guard !isSaving, !changingCapture else { return }
    changingCapture = true
    defer {
      changingCapture = false
      flushDeferredDraft()
    }
    captureRevision += 1
    let next = CaptureDraftSnapshot()
    do {
      try await captureDrafts.save(next, revision: captureRevision)
      captureMemoID = next.memoID
      pendingAssets = []
      captureDraftReady = true
      draft = ""
      needsDraftSave = false
    } catch { report(error) }
  }

  func pin(_ entry: NotebookEntry) async {
    do {
      try await store.setPinned(entry, pinned: entry.memo.pinnedAt == nil)
      await refresh()
    } catch { report(error) }
  }

  func trash(_ entry: NotebookEntry) async -> Bool {
    do {
      lastDeleted = try await store.trash(entry)
      await refresh()
      return true
    } catch {
      report(error)
      return false
    }
  }

  func restore(_ receipt: NotebookTrashReceipt) async -> Bool {
    do {
      try await store.restore(receipt)
      if lastDeleted?.id == receipt.id { lastDeleted = nil }
      await refresh()
      return true
    } catch {
      report(error)
      return false
    }
  }

  func restoreLastDeleted() async {
    guard let lastDeleted else { return }
    _ = await restore(lastDeleted)
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
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    config.usesAPIKey = AIProvider.matching(configuration: config).requiresAPIKey || !key.isEmpty
    if config.usesAPIKey && key.isEmpty { throw AIError.unauthorized }
    let origin = try config.origin
    _ = try config.endpoint
    let encoded = try JSONEncoder().encode(config)
    // Saving an anonymous custom connection must also remove any older key for
    // that origin, even when another connection was the most recently saved one.
    try KeychainSecretStore.save(key, origin: origin)
    preferences.set(encoded, forKey: Self.connectionKey)
    configuration = config
  }

  func report(_ error: Error) {
    if error is NotebookError || error is AIError || error is KeychainSecretStore.Failure
      || error is CaptureDraftError
    {
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
