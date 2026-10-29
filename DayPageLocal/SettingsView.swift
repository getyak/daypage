import DayPageCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject private var notebook: NotebookModel
  @AppStorage("local.appearance") private var appearance = "system"
  @State private var connection = AIConfiguration()
  @State private var key = ""
  @State private var keyOrigin: String?
  @State private var importing = false
  @State private var exporting = false
  @State private var saved = false
  @State private var testing = false
  @State private var connectionMessage: String?
  @State private var testTask: Task<Void, Never>?

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          Text("Your AI.\nYour choice.").font(NotebookTheme.reading(30))
          Text(
            "Writing works offline. Only when you send a question will the listed note excerpts go to the AI service you choose."
          )
          .font(.subheadline).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
      }
      .listRowBackground(Color.clear)

      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("Base URL").font(.caption).foregroundStyle(.secondary)
          TextField("https://your-provider.example/v1", text: $connection.baseURL)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("ai-base-url")
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Model").font(.caption).foregroundStyle(.secondary)
          TextField("Model name", text: $connection.model)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("ai-model")
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("API key · optional").font(.caption).foregroundStyle(.secondary)
          SecureField("Leave blank for an anonymous local server", text: $key)
            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            .accessibilityIdentifier("ai-key")
        }
        Toggle("Allow local network HTTP", isOn: $connection.allowsLocalHTTP)
          .accessibilityIdentifier("ai-local-http")
        Text(
          "Local HTTP is unencrypted. Use it only with a trusted device on your private network. On iPhone, localhost means the iPhone; use your computer’s LAN address for a desktop model."
        )
        .font(.caption).foregroundStyle(.secondary)
      } header: {
        Text("AI connection")
      } footer: {
        Text(
          "Compatible with OpenAI-style chat APIs, including local model servers. Keys stay in this device’s Keychain and are kept separate for each service."
        )
      }
      .disabled(testing)

      Section {
        Button {
          do {
            guard try connection.origin == keyOrigin else {
              key = ""
              reloadKey()
              throw AIError.configuration
            }
            try notebook.saveConnection(connection, key: key)
            saved = true
          } catch { notebook.report(error) }
        } label: {
          Label(
            saved ? "Connection saved" : "Save connection",
            systemImage: saved ? "checkmark" : "checkmark.circle")
        }
        .accessibilityIdentifier("save-ai-connection")
        .disabled(testing || (try? connection.endpoint) == nil)
        Button {
          guard (try? connection.origin) == keyOrigin else {
            key = ""
            reloadKey()
            return
          }
          testing = true
          connectionMessage = nil
          let config = connection
          let secret = key
          testTask = Task {
            defer { testing = false }
            do {
              _ = try await AIClient().complete(
                configuration: config, apiKey: secret,
                messages: [.init(role: .user, content: "Reply with OK.")],
                context: .build(entries: [], question: ""))
              connectionMessage = String(localized: "Connected. No notes were sent for this test.")
            } catch is CancellationError {} catch {
              connectionMessage = String(
                localized:
                  "Connection failed. Check the address, model and key. No notes were sent.")
            }
          }
        } label: {
          HStack {
            Text("Test connection without notes")
            if testing { ProgressView() }
          }
        }
        .disabled(testing || (try? connection.endpoint) == nil)
        .accessibilityIdentifier("test-ai-connection")
        if let connectionMessage {
          Text(connectionMessage).font(.caption).foregroundStyle(.secondary)
        }
      }
      .listRowBackground(NotebookTheme.card)

      Section("On this device") {
        Button {
          importing = true
        } label: {
          Label(
            notebook.isImporting ? "Importing a copy…" : "Import a copy of an older Vault",
            systemImage: "folder.badge.plus")
        }
        .disabled(notebook.isImporting)
        .accessibilityIdentifier("import-vault")
        Button {
          exporting = true
        } label: {
          Label("Export notebook files", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("export-vault")
        Text(
          "Older iCloud notes are not moved automatically. Download the whole Vault in Files, then select its folder here. Originals stay untouched; imported copies are kept separately from local notes."
        )
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
        Text("DayPage Local · 0.5\nMarkdown notes. No account. No database.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .listRowBackground(Color.clear)
    }
    .scrollContentBackground(.hidden)
    .notebookSurface()
    .onAppear {
      connection = notebook.configuration
      reloadKey()
    }
    .onChange(of: connection.baseURL) { _ in
      saved = false
      reloadKey()
    }
    .onChange(of: connection.model) { _ in
      saved = false
      reloadKey()
    }
    .onChange(of: connection.allowsLocalHTTP) { _ in
      saved = false
      reloadKey()
    }
    .onChange(of: key) { value in
      saved = false
      connection.usesAPIKey = !value.isEmpty
    }
    .onDisappear { testTask?.cancel() }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
      switch result {
      case .success(let url): Task { await notebook.importVault(url) }
      case .failure(let error): notebook.report(error)
      }
    }
    .fileExporter(
      isPresented: $exporting, document: VaultExport(root: notebook.root), contentType: .folder,
      defaultFilename: "DayPage Vault"
    ) { result in
      if case .failure(let error) = result { notebook.report(error) }
    }
  }

  private func reloadKey() {
    let origin = try? connection.origin
    guard origin != keyOrigin else { return }
    keyOrigin = origin
    do {
      if origin == (try? notebook.configuration.origin), notebook.configuration.usesAPIKey,
        let origin
      {
        key = try KeychainSecretStore.read(origin: origin)
      } else {
        key = ""
      }
    } catch {
      key = ""
      notebook.report(error)
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
