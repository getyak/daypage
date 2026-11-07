import DayPageCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject private var notebook: NotebookModel
  @AppStorage("local.appearance") private var appearance = "system"
  @State private var importing = false
  @State private var exporting = false
  @State private var modelsOpen = false
  @State private var speechOpen = false
  private var notePreviewText: String {
    String(localized: "A little space for a thought.\n留一点空间，记下此刻的想法。")
  }
  private var noteFontStyleName: LocalizedStringKey {
    switch notebook.noteTypography.style {
    case .serif: return "Serif"
    case .system: return "System"
    case .rounded: return "Rounded"
    case .monospaced: return "Monospaced"
    }
  }

  var body: some View {
    Form {
      Section {
        Button { modelsOpen = true } label: {
          HStack {
            Label("AI models", systemImage: "sparkles")
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
          }.frame(minHeight: 44)
        }.accessibilityIdentifier("settings-ai-models")
        Button { speechOpen = true } label: {
          HStack {
            Label("Speech channels", systemImage: "speaker.wave.2")
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
          }.frame(minHeight: 44)
        }.accessibilityIdentifier("settings-speech")
      }.listRowBackground(NotebookTheme.card)
      Section("On this device") {
        Button { NotificationCenter.default.post(name: ScreenshotInboxLocation.reviewRequested, object: nil) } label: {
          Label("Review shared images", systemImage: "tray")
        }.accessibilityIdentifier("settings-shared-images")
        NavigationLink {
          ContinuitySettingsView()
        } label: {
          Label("Devices & iCloud", systemImage: "icloud")
        }.accessibilityIdentifier("settings-continuity")
        Button { importing = true } label: {
          Label(notebook.isImporting ? "Importing a copy…" : "Import a copy of an older Vault",
                systemImage: "folder.badge.plus")
        }
        .disabled(notebook.isImporting).accessibilityIdentifier("import-vault")
        Button { exporting = true } label: {
          Label("Export notebook files", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("export-vault")
        Text("Older iCloud notes are not moved automatically. Download the whole Vault in Files, then select its folder here. Originals stay untouched; imported copies are kept separately from local notes.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .listRowBackground(NotebookTheme.card)
      Section("Appearance") {
        Picker("Theme", selection: $appearance) {
          Text("System").tag("system")
          Text("Light").tag("light")
          Text("Dark").tag("dark")
        }
        .accessibilityIdentifier("appearance-picker")
      }
      .listRowBackground(NotebookTheme.card)
      Section("Reading") {
        Picker("Font style", selection: $notebook.noteTypography.style) {
          Text("Serif").tag(NoteTypography.Style.serif)
          Text("System").tag(NoteTypography.Style.system)
          Text("Rounded").tag(NoteTypography.Style.rounded)
          Text("Monospaced").tag(NoteTypography.Style.monospaced)
        }
        .accessibilityLabel("Font style")
        .accessibilityValue(Text(noteFontStyleName))
        .accessibilityIdentifier("note-font-style")
        Stepper(value: $notebook.noteTypography.size, in: NoteTypography.sizeRange, step: 1) {
          HStack {
            Text("Font size")
            Text(notebook.noteTypography.size, format: .number.precision(.fractionLength(0)))
              .monospacedDigit().foregroundStyle(NotebookTheme.muted)
          }.frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityLabel("Font size")
        .accessibilityValue(Text(notebook.noteTypography.size, format: .number.precision(.fractionLength(0))))
        .accessibilityIdentifier("note-font-size")
        VStack(alignment: .leading, spacing: 12) {
          Text("Preview").font(.caption).foregroundStyle(NotebookTheme.muted)
          Text(notePreviewText)
            .noteReadingStyle(notebook.noteTypography, text: notePreviewText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("note-typography-preview")
        }
        .padding(.vertical, 8)
      }
      .listRowBackground(NotebookTheme.card)
      Section {
        if let policyURL = URL(string: "https://github.com/getyak/daypage/blob/main/docs/legal/ios-privacy.md") {
          Link(destination: policyURL) {
            Label("Privacy policy", systemImage: "hand.raised")
              .frame(minHeight: 44)
          }
          .accessibilityIdentifier("settings-privacy-policy")
        }
      }
      .listRowBackground(NotebookTheme.card)
      Section {
        Text("DayPage · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
          .font(.caption).foregroundStyle(.secondary)
      }
      .listRowBackground(Color.clear)
    }
    .scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).notebookSurface()
    .sheet(isPresented: $modelsOpen) {
      NavigationStack {
        AIModelsView().toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Done") { modelsOpen = false } }
        }
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
      switch result {
      case .success(let url): Task { await notebook.importVault(url) }
      case .failure(let error): notebook.report(error)
      }
    }
    .sheet(isPresented: $speechOpen) {
      NavigationStack {
        SpeechSettingsView(defaults: notebook.preferences).toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Done") { speechOpen = false } }
        }
      }
    }
    .fileExporter(isPresented: $exporting, document: VaultExport(root: notebook.root),
                  contentType: .folder, defaultFilename: "DayPage Vault") { result in
      if case .failure(let error) = result { notebook.report(error) }
    }
  }
}

struct AIModelsView: View {
  var body: some View {
    AIConnectionSettings { EmptyView() }
      .navigationTitle("AI models").navigationBarTitleDisplayMode(.inline)
      .scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).notebookSurface()
  }
}

private struct VaultExport: FileDocument {
  static let readableContentTypes: [UTType] = [.folder]
  let root: URL
  init(root: URL) { self.root = root }
  init(configuration: ReadConfiguration) throws { throw NotebookError.invalidVault }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    if !FileManager.default.fileExists(atPath: root.path) {
      return FileWrapper(directoryWithFileWrappers: [:])
    }
    return try FileWrapper(url: root, options: [])
  }
}
