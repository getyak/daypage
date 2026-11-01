import DayPageCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject private var notebook: NotebookModel
  @AppStorage("local.appearance") private var appearance = "system"
  @State private var importing = false
  @State private var exporting = false

  var body: some View {
    AIConnectionSettings {
      Section("On this device") {
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
      Section {
        Text("DayPage · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
          .font(.caption).foregroundStyle(.secondary)
      }
      .listRowBackground(Color.clear)
    }
    .scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).notebookSurface()
    .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
      switch result {
      case .success(let url): Task { await notebook.importVault(url) }
      case .failure(let error): notebook.report(error)
      }
    }
    .fileExporter(isPresented: $exporting, document: VaultExport(root: notebook.root),
                  contentType: .folder, defaultFilename: "DayPage Vault") { result in
      if case .failure(let error) = result { notebook.report(error) }
    }
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
