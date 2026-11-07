import DayPageCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class ManualReviewModel: ObservableObject {
  @Published var candidates: [NotebookEntry] = []
  @Published var selected: Set<String> = []
  @Published var period: ReviewPeriod?
  @Published var allowsAI = false
  @Published var generating = false
  @Published var saving = false
  @Published var loading = false
  @Published var result: ManualReviewDraft?
  @Published var body = ""
  @Published var pages: [SavedManualReview] = []
  @Published var error: String?
  private var session: ManualReviewSession?
  private var task: Task<Void, Never>?
  private var epoch = UUID()

  func load(notebook: NotebookModel, kind: ReviewPeriod.Kind, date: Date) async {
    invalidate()
    let current = UUID(); epoch = current; loading = true
    defer { if epoch == current { loading = false } }
    do {
      let period = try ReviewPeriod(kind: kind, anchor: date, timeZone: .current)
      let entries = try await notebook.store.entries()
      let pages = try await notebook.store.manualReviews()
      guard epoch == current, !Task.isCancelled else { return }
      self.period = period
      candidates = entries.filter { period.contains($0.memo.created) }
        .sorted { $0.memo.created < $1.memo.created }
      selected = candidates.count <= 12 ? Set(candidates.map(\.id)) : []
      self.pages = pages; session = ManualReviewSession(store: notebook.store); error = nil
    } catch { if epoch == current { self.error = Self.message(error) } }
  }
  func toggle(_ id: String) {
    invalidate()
    if selected.contains(id) { selected.remove(id) }
    else if selected.count < 12 { selected.insert(id) }
  }
  func invalidate() {
    epoch = UUID(); task?.cancel(); task = nil; session?.cancel()
    generating = false; saving = false; loading = false; allowsAI = false; result = nil; body = ""
  }
  func setConsent(_ value: Bool) { if value { allowsAI = true } else { invalidate() } }
  func generate(notebook: NotebookModel) {
    guard allowsAI, !generating, !saving, !loading, let period, let session else { return }
    do {
      let snapshot = try ManualReviewSnapshot.make(period: period, entries: candidates, selectedIDs: selected)
      let config = notebook.configuration
      _ = try config.endpoint
      let key = config.usesAPIKey ? try KeychainSecretStore.read(origin: config.origin) : ""
      let current = UUID(); epoch = current; generating = true; error = nil; result = nil
      task = Task {
        defer { if epoch == current { generating = false; task = nil } }
        do {
          let draft = try await session.generate(snapshot: snapshot, configuration: config, apiKey: key, enabled: true)
          guard epoch == current, !Task.isCancelled else { return }
          result = draft; body = draft.body
        } catch { if epoch == current { self.error = Self.message(error) } }
      }
    } catch { error = Self.message(error) }
  }
  func save() {
    guard !generating, !saving, allowsAI, let result, let session else { return }
    let current = epoch, text = body
    saving = true; error = nil
    task = Task {
      defer { if epoch == current { saving = false; task = nil } }
      do {
        let page = try await session.save(result, editedBody: text)
        guard epoch == current, !Task.isCancelled else { return }
        pages.removeAll { $0.namespace.isEmpty && $0.page.id == page.id }
        pages.insert(SavedManualReview(namespace: "", page: page), at: 0)
        self.result = nil; body = ""; allowsAI = false
      } catch { if epoch == current { self.error = Self.message(error) } }
    }
  }
  static func message(_ error: Error) -> String {
    if let error = error as? ManualReviewError { return NSLocalizedString(error.localizedDescription, comment: "") }
    if error is CancellationError { return String(localized: "Review stopped. Your notes have not changed.") }
    return String(localized: "Could not finish this review. Check the sources and AI settings, then try again.")
  }
}

struct ManualReviewsView: View {
  @EnvironmentObject private var notebook: NotebookModel
  @StateObject private var review = ManualReviewModel()
  @State private var kind: ReviewPeriod.Kind = .day
  @State private var date = Date()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Review range") {
          Picker("Period", selection: $kind) { Text("Day").tag(ReviewPeriod.Kind.day); Text("Week").tag(ReviewPeriod.Kind.week) }
            .pickerStyle(.segmented)
          DatePicker("Date", selection: $date, displayedComponents: .date)
          if let period = review.period {
            Text(period.title).font(.headline)
            Text(period.timeZoneID).font(.caption).foregroundStyle(.secondary)
          }
          Text("Weeks run Monday through Sunday. Only the selected note text is used; attachments are not sent.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Section("Sources to send") {
          if review.loading { ProgressView("Loading sources…") }
          else if review.candidates.isEmpty { Text("No notes in this range.") }
          ForEach(review.candidates) { entry in
            VStack(alignment: .leading, spacing: 8) {
            Button { review.toggle(entry.id) } label: {
              HStack(alignment: .top) {
                Image(systemName: review.selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading, spacing: 5) {
                  Text(entry.memo.created, style: .date).font(.caption)
                  Text(entry.memo.body.isEmpty ? String(localized: "No text; attachments are excluded") : entry.memo.body)
                    .lineLimit(6).foregroundStyle(.primary)
                  if !entry.namespace.isEmpty { Text("Imported notebook").font(.caption).foregroundStyle(.secondary) }
                }
              }.frame(minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain).disabled(review.generating || review.saving)
              DisclosureGroup("Read source text") { Text(entry.memo.body).textSelection(.enabled) }
                .disabled(review.generating || review.saving)
            }
          }
          Text("Select up to 12 notes. Nothing is silently truncated.").font(.footnote).foregroundStyle(.secondary)
          Button("Reload sources") { Task { await reload() } }.disabled(review.generating || review.saving)
        }
        Section {
          Toggle("Allow this AI request", isOn: Binding(get: { review.allowsAI }, set: { review.setConsent($0) }))
          Text("Generate sends the selected text to the AI service you configured. No background generation is enabled.")
            .font(.footnote).foregroundStyle(.secondary)
          if review.generating {
            ProgressView("Generating review…")
            Button("Cancel generation") { review.invalidate() }
          } else {
            Button("Generate review") { review.generate(notebook: notebook) }
              .disabled(!review.allowsAI || review.selected.isEmpty || review.loading || review.saving)
              .accessibilityIdentifier("generate-manual-review")
          }
          if let error = review.error { Text(error).foregroundStyle(.secondary) }
        }
        if review.result != nil {
          Section("Review before saving") {
            TextEditor(text: $review.body).frame(minHeight: 240)
            Text("AI output may be incomplete. Check it against the selected sources before saving.")
              .font(.footnote).foregroundStyle(.secondary)
            Button("Save review page") { review.save() }.disabled(review.saving || !review.allowsAI)
              .accessibilityIdentifier("save-manual-review")
          }
        }
        Section("Saved review pages") {
          if review.pages.isEmpty { Text("No saved review pages yet.") }
          ForEach(review.pages) { record in
            NavigationLink { ManualReviewPageView(record: record) } label: {
              VStack(alignment: .leading, spacing: 5) {
                Text(record.page.period.title)
                Text(record.page.created, style: .date).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          Text("Review pages are local files. Export them explicitly to share them with another app or device.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Day and week reviews").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { review.invalidate(); dismiss() }.disabled(review.saving) } }
      .task(id: "\(kind.rawValue)-\(date.timeIntervalSince1970)") { await reload() }
      .onChange(of: notebook.configuration) { _ in review.invalidate() }
      .onDisappear { review.invalidate() }
    }
  }
  private func reload() async { await review.load(notebook: notebook, kind: kind, date: date) }
}

private struct ManualReviewPageView: View {
  let record: SavedManualReview
  @EnvironmentObject private var notebook: NotebookModel
  @State private var exporting = false
  @State private var exportError: String?
  var body: some View {
    List {
      Section {
        Text(record.page.body).textSelection(.enabled).font(NotebookTheme.reading(17))
        Text(record.page.period.timeZoneID).font(.caption).foregroundStyle(.secondary)
      }
      Section("Sources") {
        ForEach(record.page.citations) { source in
          let id = record.namespace.isEmpty ? source.id : record.namespace + (source.id.hasPrefix("/") ? "" : "/") + source.id
          if let entry = notebook.entries.first(where: { $0.id == id }) {
            NavigationLink { NoteDetailView(entry: entry) } label: {
              VStack(alignment: .leading) {
                Text(source.day)
                if entry.revision != source.revision { Text("Source changed since generation").font(.caption).foregroundStyle(.secondary) }
              }
            }
          } else { Text("Source unavailable").foregroundStyle(.secondary) }
        }
      }
      Section {
        Button("Export review Markdown") { exporting = true }
        if let exportError { Text(exportError).foregroundStyle(.secondary) }
      }
    }
    .navigationTitle(record.page.period.title)
    .fileExporter(isPresented: $exporting, document: ManualReviewDocument(page: record.page), contentType: ManualReviewDocument.markdownType,
      defaultFilename: "DayPage review " + record.page.period.firstDay + ".md") { result in
      if case .failure = result { exportError = String(localized: "The review could not be exported. Its local file is unchanged.") }
    }
  }
}

private struct ManualReviewDocument: FileDocument {
  static let markdownType = UTType(filenameExtension: "md") ?? .plainText
  static var readableContentTypes: [UTType] { [.plainText] }
  let data: Data
  init(page: ManualReviewPage) { data = (try? page.encoded()) ?? Data() }
  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else { throw ManualReviewError.page }
    self.data = data
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    guard !data.isEmpty else { throw ManualReviewError.page }
    return FileWrapper(regularFileWithContents: data)
  }
}
