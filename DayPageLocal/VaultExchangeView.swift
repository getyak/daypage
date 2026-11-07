import DayPageCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class VaultExchangeModel: ObservableObject {
  @Published var pending: [PendingVaultImport] = []
  @Published var selected: PendingVaultImport?
  @Published var records: ExchangeRecords?
  @Published var outgoing: VaultExchangeSnapshot?
  @Published var busy = false
  @Published var message: String?
  private var coordinator: VaultExchangeImport?
  private var task: Task<Void, Never>?
  private var epoch = UUID()

  func load(notebook: NotebookModel) async {
    if coordinator == nil { coordinator = VaultExchangeImport(root: notebook.root) }
    do { pending = try await coordinator?.pendingImports() ?? [] }
    catch { message = Self.message(error) }
  }
  func prepareExport(notebook: NotebookModel, scope: String, date: Date) {
    guard !busy else { return }
    busy = true; message = nil; outgoing = nil
    let current = UUID(); epoch = current
    task = Task {
      defer { if epoch == current { busy = false; task = nil } }
      do {
        let ids: Set<String>?
        if scope == "all" { ids = nil }
        else {
          let period = try ReviewPeriod(kind: scope == "day" ? .day : .week, anchor: date, timeZone: .current)
          ids = Set(try await notebook.store.entries().filter { period.contains($0.memo.created) }.map(\.id))
        }
        let snapshot = try await notebook.store.exchangeSnapshot(selectedIDs: ids)
        try Task.checkCancellation()
        guard epoch == current else { return }
        outgoing = snapshot
      } catch { if epoch == current { message = Self.message(error) } }
    }
  }
  func choose(_ job: PendingVaultImport) {
    guard !busy, let coordinator else { return }
    busy = true; message = nil; records = nil; selected = job
    let current = UUID(); epoch = current
    task = Task {
      defer { if epoch == current { busy = false; task = nil } }
      do {
        if job.phase == .ready {
          let preview = try await coordinator.preview(job)
          guard epoch == current, !Task.isCancelled else { return }
          records = preview
        }
      } catch { if epoch == current { message = Self.message(error) } }
    }
  }
  func receive(_ url: URL, resuming: PendingVaultImport?, notebook: NotebookModel) {
    guard !busy, let coordinator else { return }
    busy = true; message = nil; records = nil
    let current = UUID(); epoch = current
    task = Task {
      defer { if epoch == current { busy = false; task = nil } }
      do {
        let job: PendingVaultImport
        if let resuming { job = try await coordinator.resume(resuming, from: url) }
        else { job = try await coordinator.prepare(from: url) }
        let preview = job.phase == .ready ? try await coordinator.preview(job) : nil
        let jobs = try await coordinator.pendingImports()
        guard epoch == current, !Task.isCancelled else { return }
        selected = job; records = preview; pending = jobs
      } catch {
        if epoch == current { message = Self.message(error) }
        await load(notebook: notebook)
      }
    }
  }
  func confirm(notebook: NotebookModel) {
    guard !busy, let coordinator, let selected,
      selected.phase == .ready || selected.phase == .published else { return }
    busy = true; message = nil
    let current = UUID(); epoch = current
    task = Task {
      defer { if epoch == current { busy = false; task = nil } }
      do {
        _ = try await coordinator.confirm(selected)
        await notebook.refresh()
        let jobs = try await coordinator.pendingImports()
        guard epoch == current else { return }
        self.selected = nil; records = nil; pending = jobs
        message = String(localized: "Imported into a new notebook. Existing notes were not replaced.")
      } catch { if epoch == current { message = Self.message(error) } }
    }
  }
  func discard(_ job: PendingVaultImport, notebook: NotebookModel) {
    guard !busy, let coordinator else { return }
    busy = true
    let current = UUID(); epoch = current
    task = Task {
      defer { if epoch == current { busy = false; task = nil } }
      do {
        try await coordinator.discard(job)
        let jobs = try await coordinator.pendingImports()
        guard epoch == current else { return }
        pending = jobs
        if selected?.id == job.id { selected = nil; records = nil }
      } catch { if epoch == current { message = Self.message(error) } }
    }
  }
  func cancel() { epoch = UUID(); task?.cancel(); task = nil; busy = false }
  static func message(_ error: Error) -> String {
    if let error = error as? VaultExchangeError { return NSLocalizedString(error.localizedDescription, comment: "") }
    if error is CancellationError { return String(localized: "Exchange stopped. Pending copies remain available to review.") }
    return String(localized: "The exchange could not be completed. Original files were preserved.")
  }
}

struct VaultExchangeView: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var exchange = VaultExchangeModel()
  @State private var scope = "all"
  @State private var date = Date()
  @State private var importing = false
  @State private var exporting = false
  @State private var resumeJob: PendingVaultImport?
  @State private var discardJob: PendingVaultImport?
  var openImporterOnArrival = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Export scope") {
          Picker("Notes", selection: $scope) {
            Text("Entire notebook").tag("all"); Text("Day").tag("day"); Text("Week").tag("week")
          }
          if scope != "all" { DatePicker("Date", selection: $date, displayedComponents: .date) }
          Text("Only selected raw notes, referenced attachments and matching saved review pages are included. Private chat and draft sidecars are excluded.")
            .font(.footnote).foregroundStyle(.secondary)
          Button("Preview export") { exchange.prepareExport(notebook: notebook, scope: scope, date: date) }.disabled(exchange.busy)
            .accessibilityIdentifier("preview-vault-exchange-export")
        }
        if let outgoing = exchange.outgoing {
          Section("Export preview") {
            summary(outgoing.manifest)
            recordPreview(outgoing.records)
            Button("Choose export destination") { exporting = true }.disabled(exchange.busy)
              .accessibilityIdentifier("confirm-vault-exchange-export")
          }
        }
        Section("Import files") {
          Button("Choose an exchange or older Vault folder") { resumeJob = nil; importing = true }.disabled(exchange.busy)
            .accessibilityIdentifier("choose-vault-exchange-import")
          Text("Files are checked in a pending copy first. Confirming creates a new imported notebook. Enabled iCloud sync may then copy imported notes under your existing settings.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        if let selected = exchange.selected {
          Section("Import preview") {
            Text(selected.sourceName).font(.headline)
            if let manifest = selected.manifest { summary(manifest) }
            Text("Destination: a new imported notebook").font(.subheadline)
            if let records = exchange.records { recordPreview(records) }
            if selected.phase == .ready {
              Button("Confirm import") { exchange.confirm(notebook: notebook) }.disabled(exchange.busy || exchange.records == nil)
                .accessibilityIdentifier("confirm-vault-exchange-import")
            } else if selected.phase == .published {
              Text("This import was already published. Only its pending receipt needs cleanup.")
              Button("Finish cleanup") { exchange.confirm(notebook: notebook) }.disabled(exchange.busy)
            }
          }
        }
        Section("Pending imports") {
          if exchange.pending.isEmpty { Text("No pending imports.") }
          ForEach(exchange.pending) { job in
            VStack(alignment: .leading, spacing: 8) {
              Text(job.sourceName).font(.headline)
              Text(ByteCountFormatter.string(fromByteCount: Int64(job.byteCount), countStyle: .file)).font(.caption)
              if job.phase == .ready || job.phase == .published {
                Button("Review pending import") { exchange.choose(job) }.disabled(exchange.busy)
              } else if job.phase == .needsSource {
                Button("Select the same source to resume") { resumeJob = job; importing = true }.disabled(exchange.busy)
              } else { Text("This interrupted copy needs a fresh source selection or explicit discard.").font(.caption) }
              Button("Discard pending copy", role: .destructive) { discardJob = job }.disabled(exchange.busy)
            }
          }
        }
        if exchange.busy { ProgressView("Checking files…") }
        if let message = exchange.message { Section { Text(message).foregroundStyle(.secondary) } }
      }
      .navigationTitle("Exchange notebook files").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { exchange.cancel(); dismiss() } } }
      .task {
        await exchange.load(notebook: notebook)
        if openImporterOnArrival { importing = true }
      }
      .onChange(of: scope) { _ in exchange.outgoing = nil }
      .onChange(of: date) { _ in exchange.outgoing = nil }
      .onDisappear { exchange.cancel() }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result { exchange.receive(url, resuming: resumeJob, notebook: notebook) }
        resumeJob = nil
      }
      .fileExporter(isPresented: $exporting, document: exchange.outgoing.map(VaultExchangeDocument.init), contentType: .folder,
        defaultFilename: "DayPage exchange") { result in
        if case .failure = result { exchange.message = String(localized: "The export was not completed. Your notebook is unchanged.") }
      }
      .confirmationDialog("Discard this pending copy? Source files and published notes stay untouched.", isPresented: Binding(
        get: { discardJob != nil }, set: { if !$0 { discardJob = nil } }), titleVisibility: .visible, presenting: discardJob) { job in
          Button("Discard pending copy", role: .destructive) { exchange.discard(job, notebook: notebook) }
          Button("Cancel", role: .cancel) { }
        }
    }
  }
  private func summary(_ manifest: VaultExchangeManifest) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Notes: \(manifest.notesCount) · Review pages: \(manifest.reviewsCount)")
      Text(ByteCountFormatter.string(fromByteCount: Int64(manifest.byteCount), countStyle: .file)).font(.caption)
    }
  }
  private func recordPreview(_ records: ExchangeRecords) -> some View {
    DisclosureGroup("Read included content") {
      ForEach(Array(records.notes.enumerated()), id: \.offset) { _, note in
        VStack(alignment: .leading, spacing: 5) {
          Text(note.day).font(.caption)
          Text(note.body).textSelection(.enabled)
          if !note.attachments.isEmpty { Text("Attachments: \(note.attachments.count)").font(.caption) }
        }.padding(.vertical, 6)
      }
      ForEach(Array(records.reviews.enumerated()), id: \.offset) { _, review in
        Text(review.body).textSelection(.enabled).padding(.vertical, 6)
      }
    }
  }
}

private struct VaultExchangeDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.folder] }
  let snapshot: VaultExchangeSnapshot
  init(_ snapshot: VaultExchangeSnapshot) { self.snapshot = snapshot }
  init(configuration: ReadConfiguration) throws { throw VaultExchangeError.invalid }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    try snapshot.validated()
    let root = FileWrapper(directoryWithFileWrappers: [:])
    var files = snapshot.files
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    files["daypage-exchange.json"] = try encoder.encode(snapshot.manifest)
    for (path, bytes) in files {
      let parts = path.split(separator: "/").map(String.init)
      var folder = root
      for part in parts.dropLast() {
        if let existing = folder.fileWrappers?[part] { folder = existing }
        else {
          let child = FileWrapper(directoryWithFileWrappers: [:]); child.preferredFilename = part
          folder.addFileWrapper(child); folder = child
        }
      }
      let file = FileWrapper(regularFileWithContents: bytes); file.preferredFilename = parts.last
      folder.addFileWrapper(file)
    }
    return root
  }
}
