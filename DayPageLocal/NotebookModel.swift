import DayPageCore
import Foundation
import SwiftUI
#if DEBUG
  import CryptoKit
#endif

@MainActor
final class NotebookModel: ObservableObject {
  @Published private(set) var entries: [NotebookEntry] = []
  @Published private(set) var catalog = NotebookCatalog(entries: [])
  @Published private(set) var lastCapturedNoteID: UUID?
  // A one-shot UI request, separate from the last capture's navigation event.
  @Published private(set) var pendingCaptureRevealID: UUID?
  @Published private(set) var configuration: AIConfiguration
  @Published var draft = ""
  @Published private(set) var pendingLocation: Memo.Location?
  @Published var noteTypography = NoteTypography() {
    didSet { NoteTypography.save(noteTypography, to: preferences) }
  }
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
  let speech: SpeechPlayback
  private var loaded = false
  private var captureRevision: UInt64 = 0
  private var captureMemoID = UUID()
  var captureDraftID: UUID { captureMemoID }
  private var needsDraftSave = false
  private var captureDraftReady = false
  private var changingCapture = false
  static let connectionKey = "local.ai.connection"

  init() {
    #if DEBUG
      // A dedicated session never shares GET326/GET440 fixtures or preferences.
      if Self.isQA, ProcessInfo.processInfo.arguments.contains("-qaManualReviewExchangeSession") {
        precondition(Self.reviewExchangeQASession != nil, "Invalid GET442 QA session")
      }
    #endif
    let preferences: UserDefaults
    if Self.isQA {
      guard let isolated = UserDefaults(suiteName: Self.reviewExchangeQASession.map {
        "com.daypage.qa.GET442." + $0.uuidString
      } ?? "com.daypage.qa.GET326") else {
        preconditionFailure("Cannot isolate QA preferences")
      }
      preferences = isolated
    } else {
      preferences = .standard
    }
    self.preferences = preferences
    speech = SpeechPlayback(defaults: preferences)
    var container =
      Self.isQA
      ? URL.documentsDirectory.appendingPathComponent("qa-GET-326", isDirectory: true)
      : URL.documentsDirectory
    if let session = Self.reviewExchangeQASession {
      container = container.appendingPathComponent("GET-442/" + session.uuidString, isDirectory: true)
    }
    let root = container.appendingPathComponent("vault", isDirectory: true)
    self.root = root
    #if DEBUG
      if Self.reviewExchangeQASession != nil {
        do { try Self.validateReviewExchangeQARoot(root) }
        catch { preconditionFailure("GET442 QA vault boundary is invalid") }
      }
      if Self.isQA, ProcessInfo.processInfo.arguments.contains("-qaResetNotebook") {
        // This argument has no effect in the real application bundle.
        // The QA app owns a separate sandbox and contains only synthetic data.
        try? FileManager.default.removeItem(at: Self.reviewExchangeQASession == nil ? root : container)
        preferences.removeObject(forKey: Self.connectionKey)
        preferences.removeObject(forKey: SpeechPreferencesStore.key)
        preferences.removeObject(forKey: NoteTypography.storageKey)
      }
    #endif
    store = NotebookStore(root: root)
    conversations = ConversationStore(root: root)
    captureDrafts = CaptureDraftStore(root: root)
    configuration =
      preferences.data(forKey: Self.connectionKey)
      .flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) } ?? AIConfiguration()
    noteTypography = NoteTypography.load(from: preferences)
    #if DEBUG
      let args = ProcessInfo.processInfo.arguments
      if Self.isQA, let index = args.firstIndex(of: "-qaEndpoint"), args.indices.contains(index + 1)
      {
        configuration = AIConfiguration(
          baseURL: args[index + 1], model: "fixture-model", allowsLocalHTTP: true)
      }
      if Self.reviewExchangeQASession != nil { configuration = Self.reviewExchangeQAConfiguration }
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
      pendingLocation = snapshot.location
      captureDraftReady = true
      #if DEBUG
        if Self.reviewExchangeQASession != nil { try await seedReviewExchangeQA() }
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
        if Self.isQA, ProcessInfo.processInfo.arguments.contains("-qaSeedDiaryHistory"),
          try await store.entries().isEmpty
        {
          let calendar = Calendar(identifier: .gregorian)
          for (index, offset) in [0, 1, 2, 7, 35, 70, 100, 140].enumerated() {
            let date = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            try await store.append(Memo(created: date,
              body: "Diary history \(index). A small moment from this day. #history"))
          }
          if ProcessInfo.processInfo.arguments.contains("-qaSeedDiaryPins") {
            for index in 0..<4 {
              var memo = Memo(body: "Pinned diary \(index). " + String(repeating: "A thought kept at the top of today. ", count: 12))
              memo.pinnedAt = memo.created
              try await store.append(memo)
            }
          }
        }
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
          var seeded = samples
          if ProcessInfo.processInfo.arguments.contains("-qaSeedNoteRelations") {
            seeded += [
              "Notebook pricing should leave room for a free plan. #product #pricing",
              "Experiment with a paid notebook plan while keeping a free tier. #product #pricing",
            ]
          }
          for (index, text) in seeded.enumerated() {
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

  /// The production session remains the owner of consent, source validation,
  /// cancellation and Save. Only its transport is replaced in an exact QA vault.
  func makeManualReviewSession() throws -> ManualReviewSession {
    #if DEBUG
      if Self.reviewExchangeQASession != nil {
        try requireReviewExchangeQA()
        return ManualReviewSession(store: store, generator: { [weak self] config, _, snapshot in
          guard let self else { throw ManualReviewError.revoked }
          return try await self.generateReviewExchangeQA(config: config, snapshot: snapshot)
        })
      }
    #endif
    return ManualReviewSession(store: store)
  }

  func manualReviewAPIKey(configuration: AIConfiguration) throws -> String {
    #if DEBUG
      if Self.reviewExchangeQASession != nil {
        try requireReviewExchangeQA()
        guard configuration == Self.reviewExchangeQAConfiguration else { throw ManualReviewError.revoked }
        return "" // No Keychain access and no claim of a verified provider.
      }
    #endif
    return configuration.usesAPIKey ? try KeychainSecretStore.read(origin: configuration.origin) : ""
  }

  static var reviewExchangeQASession: UUID? {
    #if DEBUG
      let args = ProcessInfo.processInfo.arguments
      let matches = args.indices.filter { args[$0] == "-qaManualReviewExchangeSession" }
      guard isQA, args.filter({ $0 == "-qaNotebookSession" }).count == 1,
        matches.count == 1, let index = matches.first, args.indices.contains(index + 1),
        let id = UUID(uuidString: args[index + 1]), id.uuidString == args[index + 1] else { return nil }
      return id
    #else
      return nil
    #endif
  }

  #if DEBUG
    @Published private(set) var reviewQACalls = 0
    @Published private(set) var reviewQACompletions = 0
    @Published private(set) var reviewQASettled = 0
    @Published var reviewQAHoldNext = false
    @Published private(set) var reviewQAProof = "Not checked"
    @Published private(set) var reviewQAReadbacks = 0
    private var reviewQAWaiters: [CheckedContinuation<Void, Never>] = []
    private static let reviewQAMemoID = UUID(uuidString: "44200000-0000-4000-8000-000000000001")!
    private static let reviewExchangeQAConfiguration = AIConfiguration(
      baseURL: "https://get442.invalid/v1", model: "local-injected-generator", usesAPIKey: false)
    private struct ReviewQABaseline: Codable {
      let protectedFiles: [String: String]
      let draft: String
      let sourceFiles: [String: String]
      let sourceMarkdown: String
      let sourceAsset: String
      let sourceRaw: [String: String]
      let sourceReviewID: UUID
      let sourceReview: String
    }
    var isReviewExchangeQA: Bool { (try? requireReviewExchangeQA()) != nil }
    private var reviewQAContainer: URL { root.deletingLastPathComponent() }

    private func requireReviewExchangeQA() throws {
      try Self.validateReviewExchangeQARoot(root)
    }
    private static func validateReviewExchangeQARoot(_ root: URL) throws {
      guard let id = Self.reviewExchangeQASession else { throw ManualReviewError.revoked }
      let base = URL.documentsDirectory.appendingPathComponent("qa-GET-326", isDirectory: true)
      let expected = base.appendingPathComponent("GET-442/" + id.uuidString + "/vault", isDirectory: true)
      guard root.standardizedFileURL == expected.standardizedFileURL else { throw ManualReviewError.revoked }
      // Check each QA-owned component. Foundation may alias the sandbox's
      // system ancestors; no link inside this session is accepted.
      for path in [base, base.appendingPathComponent("GET-442"), expected.deletingLastPathComponent(), expected]
        + ["baseline.json", "inspection.json", "synthetic-source", "synthetic-exchange"].map({ expected.deletingLastPathComponent().appendingPathComponent($0) }) {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
          attributes[.type] as? FileAttributeType == .typeSymbolicLink {
          throw ManualReviewError.revoked
        }
      }
    }
    func reviewQAImportSource() throws -> URL {
      try requireReviewExchangeQA()
      return reviewQAContainer.appendingPathComponent("synthetic-exchange", isDirectory: true)
    }
    private static func reviewQAHash(_ bytes: Data) -> String {
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func reviewQAEncode<T: Encodable>(_ value: T) throws -> Data {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(value)
    }
    private static func reviewQADraftDigest(_ snapshot: CaptureDraftSnapshot) throws -> String {
      // Backgrounding persists the ordinary draft with a newer revision.
      // Compare its actual identity/text/attachment bytes, not that save clock.
      var content = snapshot; content.revision = 0
      return reviewQAHash(try reviewQAEncode(content))
    }
    private func reviewQAFiles(_ folder: URL) throws -> [String: String] {
      try requireReviewExchangeQA()
      guard folder.standardizedFileURL.path.hasPrefix(reviewQAContainer.standardizedFileURL.path + "/") else {
        throw ManualReviewError.revoked
      }
      var result: [String: String] = [:], total = 0, directories = 0
      func walk(_ directory: URL, depth: Int = 0) throws {
        directories += 1
        guard directories <= 32, depth <= 8 else { throw ManualReviewError.limit }
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw ManualReviewError.page }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]) {
          let value = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
          guard value.isSymbolicLink != true else { throw ManualReviewError.page }
          if value.isDirectory == true { try walk(url, depth: depth + 1) }
          else {
            guard value.isRegularFile == true, let size = value.fileSize, size <= 1_048_576,
              result.count < 32, total + size <= 4_194_304 else { throw ManualReviewError.limit }
            let bytes = try Data(contentsOf: url); total += bytes.count
            guard bytes.count == size else { throw ManualReviewError.changed }
            result[String(url.path.dropFirst(folder.path.count + 1))] = Self.reviewQAHash(bytes)
          }
        }
      }
      try walk(folder)
      return result
    }
    private func seedReviewExchangeQA() async throws {
      try requireReviewExchangeQA()
      let baseline = reviewQAContainer.appendingPathComponent("baseline.json")
      if FileManager.default.fileExists(atPath: baseline.path) { return }
      let importSource = try reviewQAImportSource()
      guard !FileManager.default.fileExists(atPath: reviewQAContainer.appendingPathComponent("synthetic-source").path),
        !FileManager.default.fileExists(atPath: importSource.path) else { throw ManualReviewError.conflict }
      let existing = try await store.entries()
      guard existing.isEmpty, draft.isEmpty, pendingAssets.isEmpty else { throw ManualReviewError.conflict }
      let created = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600 + 0.123)
      try await store.append(Memo(id: Self.reviewQAMemoID, created: created,
        body: "GET442 original local note. Keep these exact bytes. #synthetic"), assets: [
          NotebookAssetInput(data: Data("GET442 original attachment\n".utf8), fileExtension: "txt", kind: "file")])
      let ordinary = CaptureDraftSnapshot(body: "GET442 ordinary unfinished draft — keep me.", assets: [
        PendingNoteAsset(data: Data("GET442 ordinary draft attachment\n".utf8), name: "ordinary.txt", fileExtension: "txt", kind: "file")])
      captureRevision += 1
      try await captureDrafts.save(ordinary, revision: captureRevision)
      captureMemoID = ordinary.memoID; draft = ordinary.body; pendingAssets = ordinary.assets
      let sourceRoot = reviewQAContainer.appendingPathComponent("synthetic-source")
      let sourceStore = NotebookStore(root: sourceRoot)
      try await sourceStore.append(Memo(id: Self.reviewQAMemoID, created: created,
        body: "GET442 imported note with the SAME ID and different original bytes."), assets: [
          NotebookAssetInput(data: Data("GET442 imported attachment\n".utf8), fileExtension: "txt", kind: "file")])
      let sourceEntries = try await sourceStore.entries()
      let sourcePeriod = try ReviewPeriod(kind: .day, anchor: created, timeZone: .current)
      let sourceSession = ManualReviewSession(store: sourceStore, generator: { _, _, _ in
        "GET442 synthetic imported review. This is fixture content, not a provider response. [S1]"
      })
      let sourceDraft = try await sourceSession.generate(snapshot: ManualReviewSnapshot.make(
        period: sourcePeriod, entries: sourceEntries, selectedIDs: Set(sourceEntries.map(\.id))),
        configuration: Self.reviewExchangeQAConfiguration, apiKey: "", enabled: true)
      let sourcePage = try await sourceSession.save(sourceDraft, editedBody: sourceDraft.body)
      let snapshot = try await sourceStore.exchangeSnapshot()
      try snapshot.validated()
      let source = importSource
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      var files = snapshot.files
      files["daypage-exchange.json"] = try Self.reviewQAEncode(snapshot.manifest)
      for (path, bytes) in files {
        let url = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
      }
      guard let sourceEntry = try await sourceStore.entries().first,
        let attachment = sourceEntry.memo.attachments.first else { throw ManualReviewError.page }
      let sourceAsset = try Data(contentsOf: await sourceStore.assetURL(attachment.file, for: sourceEntry))
      let saved = try await captureDrafts.load()
      let record = ReviewQABaseline(protectedFiles: try reviewQAFiles(root.appendingPathComponent("raw")),
        draft: try Self.reviewQADraftDigest(saved), sourceFiles: try reviewQAFiles(source),
        sourceMarkdown: sourceEntry.revision, sourceAsset: Self.reviewQAHash(sourceAsset),
        sourceRaw: try reviewQAFiles(sourceRoot.appendingPathComponent("raw")),
        sourceReviewID: sourcePage.id, sourceReview: Self.reviewQAHash(try sourcePage.encoded()))
      try Self.reviewQAEncode(record).write(to: baseline, options: .atomic)
    }
    private func generateReviewExchangeQA(config: AIConfiguration, snapshot: ManualReviewSnapshot) async throws -> String {
      try requireReviewExchangeQA()
      guard config == Self.reviewExchangeQAConfiguration else { throw ManualReviewError.revoked }
      reviewQACalls += 1
      if reviewQAHoldNext {
        reviewQAHoldNext = false
        // Deliberately noncooperative: tests release this AFTER cancellation.
        // The production session and UI must reject its late completion.
        await withCheckedContinuation { reviewQAWaiters.append($0) }
      }
      reviewQACompletions += 1
      return "GET442 synthetic \(snapshot.period.kind.rawValue) review from \(snapshot.entries.count) selected source(s). [S1]"
    }
    func releaseReviewQALateReply() {
      guard isReviewExchangeQA else { return }
      let waiters = reviewQAWaiters; reviewQAWaiters = []
      for waiter in waiters { waiter.resume() }
    }
    func reviewQARequestFinished() {
      if isReviewExchangeQA { reviewQASettled += 1 }
    }
    func refreshReviewQAProof() async {
      defer { reviewQAReadbacks += 1 }
      do {
        try requireReviewExchangeQA()
        let baseline = try JSONDecoder().decode(ReviewQABaseline.self,
          from: Data(contentsOf: reviewQAContainer.appendingPathComponent("baseline.json")))
        let entries = try await store.entries(), pages = try await store.manualReviews()
        let draft = try await captureDrafts.load()
        let pending = try await VaultExchangeImport(root: root).pendingImports()
        let imported = entries.filter { !$0.namespace.isEmpty }
        var importedBytes = true
        for entry in imported {
          guard UUID(uuidString: entry.namespace) != nil, entry.memo.id == Self.reviewQAMemoID,
            entry.revision == baseline.sourceMarkdown,
            entry.memo.attachments.count == 1 else { importedBytes = false; continue }
          let url = try await store.assetURL(entry.memo.attachments[0].file, for: entry)
          if Self.reviewQAHash(try Data(contentsOf: url)) != baseline.sourceAsset { importedBytes = false }
          let importedRoot = root.appendingPathComponent("imports/" + entry.namespace)
          if try reviewQAFiles(importedRoot.appendingPathComponent("raw")) != baseline.sourceRaw { importedBytes = false }
          let reviewFile = importedRoot.appendingPathComponent("wiki/manual-reviews/" + baseline.sourceReviewID.uuidString + ".md")
          if Self.reviewQAHash(try Data(contentsOf: reviewFile)) != baseline.sourceReview { importedBytes = false }
        }
        let unchanged = try reviewQAFiles(root.appendingPathComponent("raw")) == baseline.protectedFiles
          && Self.reviewQADraftDigest(draft) == baseline.draft
          && reviewQAFiles(reviewQAImportSource()) == baseline.sourceFiles
        let importedState = imported.isEmpty ? "none" : (importedBytes ? "verified" : "CHANGED")
        let summary = "local=\(entries.filter { $0.namespace.isEmpty }.count) imported=\(imported.count) pages=\(pages.count) day=\(pages.filter { $0.page.period.kind == .day }.count) week=\(pages.filter { $0.page.period.kind == .week }.count) importedReviews=\(pages.filter { !$0.namespace.isEmpty }.count) pending=\(pending.count) originals=\(unchanged ? "unchanged" : "CHANGED") importedBytes=\(importedState)"
        // Only the exact synthetic session's readback is serialized.
        try Self.reviewQAEncode(["session": Self.reviewExchangeQASession!.uuidString, "readback": summary])
          .write(to: reviewQAContainer.appendingPathComponent("inspection.json"), options: .atomic)
        reviewQAProof = summary
      } catch { reviewQAProof = "QA readback FAILED" }
    }
  #endif

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

  func readToolAttachment(cardRef: String, index: Int, allowedEntries: [NotebookEntry]) async throws -> String {
    guard let entry = allowedEntries.first(where: { $0.id == cardRef }),
      entry.memo.attachments.indices.contains(index) else { throw NotebookError.conflict }
    let attachment = entry.memo.attachments[index]
    let url = try await store.assetURL(attachment.file, for: entry)
    return try await AttachmentTextReader.read(url: url, kind: attachment.kind, transcript: attachment.transcript)
  }

  func saveReply(_ message: ChatMessage) async throws -> NotebookEntry {
    guard message.role == .assistant, message.delivery == .complete else { throw NotebookError.conflict }
    let entry = try await ReplyCardSaver.save(id: message.id, text: message.content, store: store)
    await refresh()
    return entry
  }

  func saveDraft() {
    guard captureDraftReady else { return }
    guard !isSaving, !changingCapture else {
      needsDraftSave = true
      return
    }
    captureRevision += 1
    let revision = captureRevision
    let snapshot = CaptureDraftSnapshot(memoID: captureMemoID, body: draft, assets: pendingAssets,
                                       location: pendingLocation)
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
          memoID: captureMemoID, body: body, assets: pendingAssets, location: pendingLocation)
        captureRevision += 1
        // Persist the identity and full draft before publishing any raw data.
        // After a crash this same ID identifies an already committed note.
        try await captureDrafts.save(snapshot, revision: captureRevision)
        try await store.append(
          Memo(id: snapshot.memoID, location: snapshot.location, body: body),
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
        pendingLocation = nil
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
        CaptureDraftSnapshot(memoID: captureMemoID, body: draft, assets: proposed,
                             location: pendingLocation),
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
        CaptureDraftSnapshot(memoID: captureMemoID, body: draft, assets: proposed,
                             location: pendingLocation),
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
      pendingLocation = nil
      captureDraftReady = true
      draft = ""
      needsDraftSave = false
    } catch { report(error) }
  }

  /// The caller's identity prevents a late location fix from entering a new draft.
  @discardableResult
  func setCaptureLocation(_ location: Memo.Location?, for draftID: UUID) async -> Bool {
    guard captureDraftReady, draftID == captureMemoID, !isSaving, !changingCapture else {
      return false
    }
    changingCapture = true
    defer {
      changingCapture = false
      flushDeferredDraft()
    }
    captureRevision += 1
    do {
      try await captureDrafts.save(
        CaptureDraftSnapshot(memoID: captureMemoID, body: draft, assets: pendingAssets,
                             location: location), revision: captureRevision)
      pendingLocation = location
      return true
    } catch {
      report(error)
      return false
    }
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
