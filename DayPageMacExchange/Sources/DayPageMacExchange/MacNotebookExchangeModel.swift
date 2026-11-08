import Combine
import DayPageCore
import Foundation

func exchangeLabel(_ key: String) -> String { NSLocalizedString(key, bundle: .module, comment: "") }

enum MacExchangeSource: String, CaseIterable, Identifiable {
  case managed, legacy
  var id: Self { self }
  var label: String { exchangeLabel(self == .managed ? "Local exchange notebook" : "Current Mac Vault (read only)") }
}

/// This adapter owns only the separate local exchange root. It has no cloud,
/// account, SyncQueue, RawStorage or credential dependency.
@MainActor
final class MacNotebookExchangeModel: ObservableObject {
  typealias Exporter = @Sendable (URL, Set<String>?) async throws -> VaultExchangeSnapshot
  @Published private(set) var entries: [NotebookEntry] = []
  @Published private(set) var reviews: [SavedManualReview] = []
  @Published private(set) var pending: [PendingVaultImport] = []
  @Published private(set) var selectedImport: PendingVaultImport?
  @Published private(set) var importPreview: ExchangeRecords?
  @Published private(set) var outgoing: VaultExchangeExportPreview?
  @Published private(set) var busy = false
  @Published private(set) var message: String?
  @Published private(set) var reviewWarning: String?
  @Published var selectedEntryID: String?
  @Published var selectedReviewID: String?
  @Published var previewURL: URL?
  let managedRoot: URL?
  private let legacyVault: () -> URL
  private let store: NotebookStore?
  private let coordinator: VaultExchangeImport?
  private let exporter: Exporter
  private var task: Task<Void, Never>?
  private var epoch = UUID()
  private var exporting = false
  private var exportSession: VaultExchangeExportSession?
  private var exportSource: MacExchangeSource?

  init(managedRoot: URL?, legacyVault: @escaping () -> URL,
    exporter: @escaping Exporter = { root, ids in try await NotebookStore(root: root).exchangeSnapshot(selectedIDs: ids) }) {
    self.managedRoot = managedRoot; self.legacyVault = legacyVault; self.exporter = exporter
    store = managedRoot.map(NotebookStore.init(root:))
    coordinator = managedRoot.map(VaultExchangeImport.init(root:))
    if managedRoot == nil { message = exchangeLabel("Local storage is unavailable. No files were changed.") }
  }
  static var defaultRoot: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("DayPage/ExchangeNotebook", isDirectory: true)
  }
  var selectedEntry: NotebookEntry? { entries.first { $0.id == selectedEntryID } }
  var selectedReview: SavedManualReview? { reviews.first { $0.id == selectedReviewID } }
  func selectEntry(_ entry: NotebookEntry) { selectedEntryID = entry.id; selectedReviewID = nil; previewURL = nil }
  func selectReview(_ review: SavedManualReview) { selectedReviewID = review.id; selectedEntryID = nil; previewURL = nil }
  func clearExport() {
    exportSession?.invalidate(); exportSession = nil; exportSource = nil
    if exporting { cancel() }
    outgoing = nil
  }
  func reportExportFailure() { message = exchangeLabel("Export was not completed. Source files are unchanged.") }
  func refresh() {
    perform { token in try await self.reload(token) }
  }
  @discardableResult
  func prepareExport(source: MacExchangeSource, scope: String, date: Date) -> Task<Void, Never>? {
    guard !busy else { return nil }
    clearExport()
    // The legacy locator is evaluated only for this explicit read action.
    guard let root = source == .legacy ? legacyVault() : managedRoot,
      let selection = try? VaultExchangeExportSelection(scope: scope, date: date, timeZone: .current) else { return nil }
    let exporter = exporter
    let session = VaultExchangeExportSession { selection in
      let ids: Set<String>?
      if selection.scope == .all { ids = nil }
      else {
        guard let zone = TimeZone(identifier: selection.timeZoneID) else { throw VaultExchangeError.invalid }
        let period = try ReviewPeriod(kind: selection.scope == .day ? .day : .week, anchor: selection.date, timeZone: zone)
        ids = Set(try await NotebookStore(root: root).exchangeEntries(period: period).map(\.id))
      }
      return try await exporter(root, ids)
    }
    let ticket = session.begin(selection)
    exportSession = session; exportSource = source
    return perform(export: true) { token in
      let preview = try await session.prepare(ticket)
      try NotebookStore.validateExchangeProjection(preview.snapshot)
      try self.requireCurrent(token)
      guard session.canExport(preview, selection: selection) else { throw VaultExchangeError.changed }
      self.outgoing = preview
    }
  }
  func exportAuthority(source: MacExchangeSource, scope: String, date: Date) -> (@Sendable () throws -> Void)? {
    guard source == exportSource, let outgoing, let exportSession,
      let selection = try? VaultExchangeExportSelection(scope: scope, date: date, timeZone: .current),
      exportSession.canExport(outgoing, selection: selection) else { return nil }
    return { guard exportSession.isCurrent(outgoing) else { throw VaultExchangeError.changed } }
  }
  func receive(_ url: URL, resuming: PendingVaultImport? = nil) {
    perform { token in
      guard let coordinator = self.coordinator else { throw VaultExchangeError.invalid }
      let job: PendingVaultImport
      if let resuming { job = try await coordinator.resume(resuming, from: url) }
      else { job = try await coordinator.prepare(from: url) }
      let records = job.phase == .ready ? try await coordinator.preview(job) : nil
      try self.requireCurrent(token)
      self.selectedImport = job; self.importPreview = records
      try await self.reload(token)
    }
  }
  func reviewImport(_ job: PendingVaultImport) {
    perform { token in
      guard let coordinator = self.coordinator else { throw VaultExchangeError.invalid }
      let records = job.phase == .ready ? try await coordinator.preview(job) : nil
      try self.requireCurrent(token)
      self.selectedImport = job; self.importPreview = records
    }
  }
  func confirmImport() {
    guard let job = selectedImport, job.phase == .ready || job.phase == .published else { return }
    perform { token in
      guard let coordinator = self.coordinator else { throw VaultExchangeError.invalid }
      let namespace = try await coordinator.confirm(job)
      try await self.reload(token)
      try self.requireCurrent(token)
      self.selectedImport = nil; self.importPreview = nil
      // The same permanent consumer immediately presents the imported content.
      if let entry = self.entries.first(where: { $0.namespace == namespace || $0.namespace.hasPrefix(namespace + "/") }) {
        self.selectEntry(entry)
      } else if let page = self.reviews.first(where: { $0.namespace == namespace || $0.namespace.hasPrefix(namespace + "/") }) {
        self.selectReview(page)
      }
      self.message = exchangeLabel("Imported copy is available below. Existing files were preserved.")
    }
  }
  func discard(_ job: PendingVaultImport) {
    perform { token in
      guard let coordinator = self.coordinator else { throw VaultExchangeError.invalid }
      try await coordinator.discard(job)
      try self.requireCurrent(token)
      if self.selectedImport?.id == job.id { self.selectedImport = nil; self.importPreview = nil }
      try await self.reload(token)
    }
  }
  func previewAttachment(_ attachment: Memo.Attachment, entry: NotebookEntry) {
    perform { token in
      guard let store = self.store else { throw VaultExchangeError.invalid }
      let file = try await store.assetURL(attachment.file, for: entry)
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
      guard values.isRegularFile == true, (values.fileSize ?? 0) <= 25 * 1024 * 1024,
        !(values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded) else { throw VaultExchangeError.invalid }
      try self.requireCurrent(token)
      self.previewURL = file // Explicit system preview, never NSWorkspace.open.
    }
  }
  func sourceEntry(_ citation: ReviewCitation, page: SavedManualReview) -> NotebookEntry? {
    let id = page.namespace.isEmpty ? citation.id : page.namespace + (citation.id.hasPrefix("/") ? "" : "/") + citation.id
    return entries.first { $0.id == id }
  }
  func cancel() {
    exportSession?.invalidate(); exportSession = nil; exportSource = nil; outgoing = nil
    epoch = UUID(); task?.cancel(); task = nil; busy = false; exporting = false; previewURL = nil
  }
  func waitUntilIdle() async { await task?.value }

  private func reload(_ token: UUID) async throws {
    guard let store, let coordinator else { throw VaultExchangeError.invalid }
    let notes = try await store.entries()
    let pages: [SavedManualReview]
    var warning: String?
    do { pages = try await store.manualReviews() }
    catch {
      try Task.checkCancellation()
      pages = []
      warning = exchangeLabel("Saved reviews could not be read. Their files are preserved; your notes are still available.")
    }
    let jobs = try await coordinator.pendingImports()
    try requireCurrent(token)
    entries = notes; reviews = pages; pending = jobs; reviewWarning = warning
    if selectedEntry == nil { selectedEntryID = nil }
    if selectedReview == nil { selectedReviewID = nil }
  }
  private func requireCurrent(_ token: UUID) throws {
    try Task.checkCancellation()
    guard epoch == token else { throw CancellationError() }
  }
  @discardableResult
  private func perform(export: Bool = false, _ action: @escaping @MainActor (UUID) async throws -> Void) -> Task<Void, Never>? {
    guard !busy, managedRoot != nil else { return nil }
    let token = UUID(); epoch = token; busy = true; exporting = export; message = nil
    task = Task {
      defer { if epoch == token { busy = false; exporting = false; task = nil } }
      do { try await action(token) }
      catch {
        guard epoch == token else { return }
        message = exchangeLabel(error is CancellationError ? "Exchange stopped. Pending copies remain available." : "Could not verify these files. Originals and pending copies were preserved.")
        // A killed/failed preparation may have created a recoverable pending
        // job. Refresh its inventory without silently publishing or deleting it.
        if let coordinator, let jobs = try? await coordinator.pendingImports(), epoch == token { pending = jobs }
      }
    }
    return task
  }
}
