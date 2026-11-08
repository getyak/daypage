import DayPageCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A real Mac consumer for the explicit file contract. The supplied legacy
/// locator grants read-only export; imports have a separate, visible local root.
@MainActor
public struct MacNotebookExchangeView: View {
  @StateObject private var model: MacNotebookExchangeModel
  @State private var source: MacExchangeSource = .managed
  @State private var scope = "all"
  @State private var date = Date()
  @State private var importing = false
  @State private var exporting = false
  @State private var resumeJob: PendingVaultImport?
  @State private var discardJob: PendingVaultImport?

  public init(legacyVault: @escaping () -> URL, managedRoot: URL? = nil) {
    _model = StateObject(wrappedValue: MacNotebookExchangeModel(
      managedRoot: managedRoot ?? MacNotebookExchangeModel.defaultRoot, legacyVault: legacyVault))
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(exchangeLabel("Notebook files")).font(.headline)
        Spacer()
        if model.busy { ProgressView().controlSize(.small) }
        Button(exchangeLabel("Refresh")) { model.refresh() }.disabled(model.busy)
          .accessibilityIdentifier("mac-exchange-refresh")
      }.padding()
      if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 10) }
      if let warning = model.reviewWarning { Text(warning).font(.callout).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 10) }
      Divider()
      HSplitView {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            exportControls
            importControls
            pendingControls
          }.padding()
        }.frame(minWidth: 240, idealWidth: 290, maxWidth: 340)
        VStack(spacing: 0) {
          contentList.frame(minHeight: 140, idealHeight: 230, maxHeight: 300)
          Divider()
          ScrollView { detail.padding().frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minWidth: 260)
      }
    }
    .navigationTitle(exchangeLabel("Notebook files"))
    .task { model.refresh() }
    .onDisappear { if !exporting { model.cancel() } }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { model.receive(url, resuming: resumeJob) }
      resumeJob = nil
    }
    .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .folder, defaultFilename: "DayPage exchange") { result in
      if case .failure = result { model.reportExportFailure() }
    }
    .quickLookPreview($model.previewURL)
    .confirmationDialog(exchangeLabel("Discard only this pending copy? Original and published files stay untouched."), isPresented: Binding(
      get: { discardJob != nil }, set: { if !$0 { discardJob = nil } }), titleVisibility: .visible, presenting: discardJob) { job in
        Button(exchangeLabel("Discard pending copy"), role: .destructive) { model.discard(job) }
        Button(exchangeLabel("Cancel"), role: .cancel) { }
      }
  }

  private var exportControls: some View {
    GroupBox(exchangeLabel("Export files")) {
      VStack(alignment: .leading, spacing: 10) {
        Picker(exchangeLabel("Source"), selection: Binding(get: { source }, set: { invalidateExport(); source = $0 })) {
          ForEach(MacExchangeSource.allCases) { Text($0.label).tag($0) }
        }.disabled(model.busy)
        Picker(exchangeLabel("Range"), selection: Binding(get: { scope }, set: { invalidateExport(); scope = $0 })) {
          Text(exchangeLabel("All notes")).tag("all")
          Text(exchangeLabel("Day")).tag("day")
          Text(exchangeLabel("Week")).tag("week")
        }.disabled(model.busy)
        if scope != "all" {
          DatePicker(exchangeLabel("Date"), selection: Binding(get: { date }, set: { invalidateExport(); date = $0 }), displayedComponents: .date)
            .disabled(model.busy)
          Text(TimeZone.current.identifier).font(.caption).foregroundStyle(.secondary)
        }
        Text(exchangeLabel("Preview reads only the chosen source. It includes selected raw notes, referenced attachments and matching saved review pages, without private runtime or chat files."))
          .font(.caption).foregroundStyle(.secondary)
        Button(exchangeLabel("Preview export")) { model.prepareExport(source: source, scope: scope, date: date) }
          .disabled(model.busy).accessibilityIdentifier("mac-exchange-preview-export")
        if let outgoing = model.outgoing, exportDocument != nil {
          manifestSummary(outgoing.snapshot.manifest)
          recordPreview(outgoing.snapshot.records)
          Button(exchangeLabel("Choose export destination")) {
            guard exportDocument != nil else { return }
            exporting = true
          }.disabled(model.busy).accessibilityIdentifier("mac-exchange-confirm-export")
        }
      }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private var importControls: some View {
    GroupBox(exchangeLabel("Import a copy")) {
      VStack(alignment: .leading, spacing: 10) {
        Text(exchangeLabel("Destination: this Mac's separate local exchange notebook. Imported copies are listed here, apart from Today and the existing cloud account."))
          .font(.caption).foregroundStyle(.secondary)
        Button(exchangeLabel("Choose an exchange or older Vault folder")) { resumeJob = nil; importing = true }
          .disabled(model.busy).accessibilityIdentifier("mac-exchange-choose-import")
        Text(exchangeLabel("Selection only prepares a pending copy. Read its content and confirm before it becomes a notebook."))
          .font(.caption).foregroundStyle(.secondary)
        if let job = model.selectedImport {
          Text(job.sourceName).font(.headline)
          if let manifest = job.manifest { manifestSummary(manifest) }
          if let records = model.importPreview { recordPreview(records) }
          if job.phase == .ready {
            Button(exchangeLabel("Confirm import into a new notebook")) { model.confirmImport() }
              .disabled(model.busy || model.importPreview == nil).accessibilityIdentifier("mac-exchange-confirm-import")
          } else if job.phase == .published {
            Text(exchangeLabel("This import is already published. Finish only its pending cleanup.")).font(.caption)
            Button(exchangeLabel("Finish cleanup")) { model.confirmImport() }.disabled(model.busy)
          }
        }
      }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private var pendingControls: some View {
    GroupBox(exchangeLabel("Pending imports")) {
      VStack(alignment: .leading, spacing: 12) {
        if model.pending.isEmpty { Text(exchangeLabel("No pending imports.")).foregroundStyle(.secondary) }
        ForEach(model.pending) { job in
          VStack(alignment: .leading, spacing: 6) {
            Text(job.phase == .unreadable ? exchangeLabel("Interrupted import") : job.sourceName).font(.headline)
            Text(ByteCountFormatter.string(fromByteCount: Int64(job.byteCount), countStyle: .file)).font(.caption)
            if job.phase == .ready || job.phase == .published {
              Button(exchangeLabel("Review pending copy")) { model.reviewImport(job) }.disabled(model.busy)
            } else if job.phase == .needsSource {
              Button(exchangeLabel("Select the same source to resume")) { resumeJob = job; importing = true }.disabled(model.busy)
            } else { Text(exchangeLabel("This interrupted copy can be discarded explicitly. Its original source is untouched.")).font(.caption) }
            Button(exchangeLabel("Discard pending copy"), role: .destructive) { discardJob = job }.disabled(model.busy)
          }
        }
      }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private var contentList: some View {
    List {
      Section(exchangeLabel("Local exchange notes")) {
        if model.entries.isEmpty { Text(exchangeLabel("No imported notes yet.")).foregroundStyle(.secondary) }
        ForEach(model.entries) { entry in
          Button { model.selectEntry(entry) } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(entry.day).font(.caption)
              Text(entry.memo.body.isEmpty ? exchangeLabel("Attachment note") : entry.memo.body).lineLimit(2)
              if !entry.namespace.isEmpty { Text(entry.namespace).font(.caption2).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityIdentifier("mac-exchange-note-" + entry.id)
        }
      }
      Section(exchangeLabel("Saved review pages")) {
        ForEach(model.reviews) { page in
          Button { model.selectReview(page) } label: {
            VStack(alignment: .leading) {
              Text(page.page.period.title)
              Text(page.page.created, style: .date).font(.caption).foregroundStyle(.secondary)
            }
          }.buttonStyle(.plain)
        }
      }
    }
  }
  @ViewBuilder private var detail: some View {
    if let entry = model.selectedEntry {
      VStack(alignment: .leading, spacing: 14) {
        Text(entry.memo.created, style: .date).font(.headline)
        Text(entry.memo.body).textSelection(.enabled)
        ForEach(Array(entry.memo.attachments.enumerated()), id: \.offset) { _, attachment in
          Button { model.previewAttachment(attachment, entry: entry) } label: {
            Label(URL(fileURLWithPath: attachment.file).lastPathComponent, systemImage: "doc.viewfinder")
          }.disabled(model.busy)
        }
        Text(exchangeLabel("Attachments open only in an explicit system preview. Nothing plays or uploads automatically."))
          .font(.caption).foregroundStyle(.secondary)
      }
    } else if let page = model.selectedReview {
      VStack(alignment: .leading, spacing: 14) {
        Text(page.page.period.title).font(.headline)
        Text(page.page.period.timeZoneID).font(.caption).foregroundStyle(.secondary)
        Text(page.page.body).textSelection(.enabled)
        Text(exchangeLabel("Historical sources")).font(.headline)
        ForEach(page.page.citations) { citation in
          if let entry = model.sourceEntry(citation, page: page) {
            Button { model.selectEntry(entry) } label: {
              VStack(alignment: .leading) {
                Text(citation.day)
                if entry.revision != citation.revision { Text(exchangeLabel("Source changed since generation")).font(.caption) }
              }
            }
          } else { Text(exchangeLabel("Source unavailable")).foregroundStyle(.secondary) }
        }
      }
    } else { Text(exchangeLabel("Select an imported note or saved review to read its full content.")).foregroundStyle(.secondary) }
  }
  private func manifestSummary(_ manifest: VaultExchangeManifest) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack { Text(exchangeLabel("Notes")); Spacer(); Text(manifest.notesCount, format: .number) }
      HStack { Text(exchangeLabel("Review pages")); Spacer(); Text(manifest.reviewsCount, format: .number) }
      Text(ByteCountFormatter.string(fromByteCount: Int64(manifest.byteCount), countStyle: .file)).font(.caption)
    }
  }
  private func recordPreview(_ records: ExchangeRecords) -> some View {
    DisclosureGroup(exchangeLabel("Read included content")) {
      LazyVStack(alignment: .leading, spacing: 10) {
        ForEach(Array(records.notes.enumerated()), id: \.offset) { _, note in
          VStack(alignment: .leading, spacing: 5) {
            Text(note.day).font(.caption)
            Text(note.body).textSelection(.enabled)
            HStack { Text(exchangeLabel("Attachments")); Text(note.attachments.count, format: .number) }.font(.caption)
          }
        }
        ForEach(Array(records.reviews.enumerated()), id: \.offset) { _, review in Text(review.body).textSelection(.enabled) }
      }
    }
  }
  private func invalidateExport() { model.clearExport(); exporting = false }
  private var exportDocument: MacExchangeDocument? {
    guard let preview = model.outgoing, let authority = model.exportAuthority(source: source, scope: scope, date: date) else { return nil }
    return MacExchangeDocument(snapshot: preview.snapshot, validate: authority)
  }
}

private struct MacExchangeDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.folder] }
  let snapshot: VaultExchangeSnapshot
  let validate: @Sendable () throws -> Void
  init(snapshot: VaultExchangeSnapshot, validate: @escaping @Sendable () throws -> Void) { self.snapshot = snapshot; self.validate = validate }
  init(configuration: ReadConfiguration) throws { throw VaultExchangeError.invalid }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    try validate(); try snapshot.validated(); try NotebookStore.validateExchangeProjection(snapshot)
    let root = FileWrapper(directoryWithFileWrappers: [:])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var files = snapshot.files; files["daypage-exchange.json"] = try encoder.encode(snapshot.manifest)
    for (path, bytes) in files {
      let parts = path.split(separator: "/").map(String.init)
      var parent = root
      for part in parts.dropLast() {
        if let folder = parent.fileWrappers?[part] { parent = folder }
        else {
          let folder = FileWrapper(directoryWithFileWrappers: [:]); folder.preferredFilename = part
          parent.addFileWrapper(folder); parent = folder
        }
      }
      let file = FileWrapper(regularFileWithContents: bytes); file.preferredFilename = parts.last
      parent.addFileWrapper(file)
    }
    try validate()
    return root
  }
}
