import DayPageCore
import SwiftUI

/// Editing is local. Only Refresh and Test start a network request.
struct AIConnectionSettings<AdditionalSettings: View>: View {
  let additionalSettings: AdditionalSettings
  @EnvironmentObject private var notebook: NotebookModel
  @State private var provider = AIProvider.openAI
  @State private var connection = AIConfiguration()
  @State private var key = ""
  @State private var keyOrigin: String?
  @State private var keyDrafts: [String: KeyDraft] = [:]
  @State private var keyReadIssue: String?
  @State private var connectionDrafts: [String: AIConfiguration] = [:]
  @State private var initialized = false
  @State private var saved = false
  @State private var busy = false
  @State private var models: [AIModelOption] = []
  @State private var resolvedModel: String?
  @State private var message: String?
  @State private var task: Task<Void, Never>?
  @State private var destination: Destination?
  @State private var modelSearch = ""
  @State private var advanced = false
  @FocusState private var focusedField: Field?
  private enum Field: Hashable { case key, address, model }
  private enum Destination: String, Identifiable {
    case providers, models
    var id: String { rawValue }
  }
  private struct KeyDraft {
    let value: String
    let needsRetry: Bool
  }
  private var keyUnavailable: String {
    String(localized: "Could not read the saved key. Unlock your device and retry. Your typed input is kept.")
  }
  init(@ViewBuilder additionalSettings: () -> AdditionalSettings) {
    self.additionalSettings = additionalSettings()
  }
  private var automatic: Bool { connection.model == AIModelCatalog.automaticModel }
  private var modelTitle: String {
    automatic ? String(localized: "Automatic · latest") : connection.model
  }
  private var canSave: Bool {
    keyReadIssue == nil && (try? connection.endpoint) != nil
      && (!provider.requiresAPIKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
  private var endpointBinding: Binding<String> {
    Binding(get: {
      // Existing connections may contain a trailing slash, explicit HTTPS port
      // or full completion path. Match their region by the validated origin.
      let origin = try? connection.origin
      return provider.endpoints.first(where: {
        (try? AIConfiguration(baseURL: $0.baseURL).origin) == origin
      })?.baseURL ?? connection.baseURL
    }, set: { connection.baseURL = $0 })
  }
  private var currentKeyURL: URL? {
    provider.endpoints.first(where: { $0.baseURL == endpointBinding.wrappedValue })?.keyURL ?? provider.keyURL
  }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Label("Your notebook", systemImage: "book.closed").font(NotebookTheme.reading(22))
          Text("Writing works offline. AI is optional.")
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
      }
      .listRowBackground(Color.clear)
      Group {
      Section {
        Button { destination = .providers } label: {
          settingRow("Provider", value: NSLocalizedString(provider.name, comment: "AI provider"))
        }
        .accessibilityIdentifier("ai-provider")
        if provider.endpoints.count > 1 {
          Picker("Region", selection: endpointBinding) {
            ForEach(provider.endpoints) { endpoint in
              Text(LocalizedStringKey(endpoint.name)).tag(endpoint.baseURL)
            }
          }
          .accessibilityIdentifier("ai-region")
        }
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(provider.requiresAPIKey ? "API key" : "API key · optional")
              .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let url = currentKeyURL {
              Link("Get an API key", destination: url).font(.caption)
                .frame(minHeight: 44).contentShape(Rectangle())
                .buttonStyle(.borderless)
                .accessibilityIdentifier("ai-get-key")
            }
          }
          SecureField("API key", text: $key)
            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            .focused($focusedField, equals: .key).submitLabel(.done)
            .onSubmit { focusedField = nil }
            .accessibilityIdentifier("ai-key")
          if let keyReadIssue {
            Text(keyReadIssue).font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("ai-key-read-issue")
            Button { reloadKey(force: true); changed() } label: {
              Text("Retry saved key").frame(minHeight: 44, alignment: .leading)
            }
              .buttonStyle(.borderless)
              .accessibilityIdentifier("ai-key-retry")
          }
        }
        .padding(.vertical, 4)
        Button { modelSearch = ""; destination = .models } label: {
          settingRow("Model", value: modelTitle.isEmpty ? String(localized: "Choose a model") : modelTitle)
        }
        .accessibilityIdentifier("ai-model-picker")
        if automatic {
          Text("Follows current general-purpose models from this provider. Availability and pricing can change.")
            .font(.caption).foregroundStyle(.secondary)
        } else if provider != .custom && !provider.supportsAutomaticModels {
          Text("This provider uses a fixed model. Automatic model discovery is not available; update the model name in Advanced when needed.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let resolvedModel {
          Label(resolvedModel, systemImage: "checkmark.circle")
            .font(.caption).foregroundStyle(NotebookTheme.readingAccent)
            .textSelection(.enabled).accessibilityIdentifier("ai-resolved-model")
        }
      } header: {
        Text("Your AI")
      } footer: {
        Text("Use a key from the selected provider and region. Keys stay in this device’s Keychain. Your notes are sent only when you tap Send in chat.")
      }
      .listRowBackground(NotebookTheme.card)

      if provider == .custom {
        Section("Custom connection") { customFields }
          .listRowBackground(NotebookTheme.card)
      } else {
        Section {
          DisclosureGroup("Advanced", isExpanded: $advanced) {
            Text(connection.baseURL).font(.caption).foregroundStyle(.secondary)
              .textSelection(.enabled).accessibilityIdentifier("ai-provider-address")
            manualModel
            Text("A fixed model stays selected until you change it. Choose Automatic to follow new models.")
              .font(.caption).foregroundStyle(.secondary)
          }
          .accessibilityIdentifier("ai-advanced")
        }
        .listRowBackground(NotebookTheme.card)
      }

      Section {
        Button(action: save) {
          Label(saved ? "Connection saved" : "Save connection", systemImage: saved ? "checkmark" : "checkmark.circle")
        }
        .disabled(!canSave).accessibilityIdentifier("save-ai-connection")
        Button { run(testing: true) } label: {
          HStack {
            Text("Test connection without notes")
            if busy { ProgressView() }
          }
        }
        .disabled(!canSave).accessibilityIdentifier("test-ai-connection")
        if let message {
          Text(message).font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("ai-connection-status")
        }
      }
      .listRowBackground(NotebookTheme.card)
      }
      .disabled(busy)
      additionalSettings
    }
    .onAppear(perform: load)
    .onDisappear { task?.cancel() }
    .onChange(of: connection.baseURL) { _ in
      reloadKey()
      models = []
      changed()
    }
    .onChange(of: connection.model) { _ in changed() }
    .onChange(of: connection.allowsLocalHTTP) { _ in changed() }
    .onChange(of: key) { _ in changed() }
    .onChange(of: destination) { _ in focusedField = nil }
    .sheet(item: $destination) { destination in
      NavigationStack {
        Group {
          switch destination {
          case .providers: providerPicker
          case .models: modelPicker
          }
        }
        .notebookSurface()
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { self.destination = nil }
          }
        }
      }
      .presentationDetents([.large])
    }
  }

  private func settingRow(_ title: LocalizedStringKey, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title).foregroundStyle(NotebookTheme.ink)
      Spacer(minLength: 8)
      Text(value).foregroundStyle(NotebookTheme.muted).multilineTextAlignment(.trailing)
    }
    .frame(minHeight: 36).contentShape(Rectangle())
  }

  private var providerPicker: some View {
    List {
      ForEach(AIProvider.allCases) { item in
        Button { choose(item); destination = nil } label: {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(LocalizedStringKey(item.name)).foregroundStyle(NotebookTheme.ink)
              if item == .custom {
                Text("OpenAI-compatible or local server").font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            if item == provider { Image(systemName: "checkmark").foregroundStyle(NotebookTheme.accent) }
          }
          .frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityIdentifier("ai-provider-" + item.id)
        .accessibilityAddTraits(item == provider ? .isSelected : [])
        .listRowBackground(NotebookTheme.card)
      }
    }
    .scrollContentBackground(.hidden).navigationTitle("Choose a provider")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var modelPicker: some View {
    List {
      if provider.supportsAutomaticModels {
        Section {
          modelButton(id: AIModelCatalog.automaticModel, name: String(localized: "Automatic · latest"))
            .accessibilityIdentifier("ai-model-auto")
        } footer: {
          Text("Follows current general-purpose models from this provider. Availability and pricing can change.")
        }
      }
      Section {
        if provider == .custom || provider.supportsAutomaticModels {
          Button { run(testing: false) } label: {
            HStack {
              Label(provider == .qwen ? LocalizedStringKey("Show model choices") : LocalizedStringKey("Refresh available models"), systemImage: "arrow.clockwise")
              if busy { ProgressView() }
            }
          }
          .disabled(busy || keyReadIssue != nil || (try? connection.origin) == nil || (provider.requiresAPIKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
          .accessibilityIdentifier("ai-refresh-models")
        }
        if let message {
          Text(message).font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("ai-model-status")
        }
        if !automatic && !connection.model.isEmpty && !models.contains(where: { $0.id == connection.model }) {
          modelButton(id: connection.model, name: connection.model)
        }
        ForEach(models.filter { modelSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(modelSearch) || $0.id.localizedCaseInsensitiveContains(modelSearch) }) { model in
          modelButton(id: model.id, name: model.name)
        }
      } header: {
        Text(provider == .qwen ? LocalizedStringKey("Suggested models") : LocalizedStringKey("Available models"))
      } footer: {
        Text("Refreshing sends no notes. You can also enter an exact model name under Advanced or Custom connection.")
      }
    }
    .disabled(busy).scrollContentBackground(.hidden)
    .searchable(text: $modelSearch, prompt: "Find a model")
    .navigationTitle("Choose a model").navigationBarTitleDisplayMode(.inline)
  }

  private func modelButton(id: String, name: String) -> some View {
    Button {
      connection.model = id
      destination = nil
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(name).foregroundStyle(NotebookTheme.ink)
          if id != name && id != AIModelCatalog.automaticModel {
            Text(id).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if id == connection.model { Image(systemName: "checkmark").foregroundStyle(NotebookTheme.accent) }
      }
      .frame(minHeight: 44).contentShape(Rectangle())
    }
    .accessibilityIdentifier("ai-choice-" + id)
    .accessibilityAddTraits(id == connection.model ? .isSelected : [])
  }

  @ViewBuilder private var customFields: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Base URL").font(.caption).foregroundStyle(.secondary)
      TextField("https://your-provider.example/v1", text: endpointBinding)
        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        .focused($focusedField, equals: .address).submitLabel(.next)
        .onSubmit { focusedField = .model }
        .accessibilityIdentifier("ai-base-url")
    }
    manualModel
    Toggle("Allow local network HTTP", isOn: $connection.allowsLocalHTTP)
      .accessibilityIdentifier("ai-local-http")
    Text("Local HTTP is unencrypted. Use it only with a trusted device on your private network. On iPhone, localhost means the iPhone; use your computer’s LAN address for a desktop model.")
      .font(.caption).foregroundStyle(.secondary)
  }

  private var manualModel: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Fixed model name").font(.caption).foregroundStyle(.secondary)
      TextField("Model name", text: Binding(
        get: { automatic ? "" : connection.model },
        set: { connection.model = $0 }
      ))
      .textInputAutocapitalization(.never).autocorrectionDisabled()
      .focused($focusedField, equals: .model).submitLabel(.done)
      .onSubmit { focusedField = nil }
      .accessibilityIdentifier("ai-model")
    }
  }

  private func load() {
    guard !initialized else { return }
    initialized = true
    let existing = notebook.configuration
    provider = existing.baseURL.isEmpty ? .openAI : AIProvider.matching(configuration: existing)
    connection = existing.baseURL.isEmpty ? provider.configuration : existing
    if !existing.baseURL.isEmpty, !existing.usesAPIKey, let origin = try? existing.origin {
      // Respect an explicitly saved anonymous connection, including older
      // versions that may have left a historical Keychain item behind.
      keyOrigin = origin
      key = ""
    } else {
      reloadKey()
    }
  }

  private func choose(_ next: AIProvider) {
    connectionDrafts[provider.id] = connection
    provider = next
    connection = connectionDrafts[next.id]
      ?? (AIProvider.matching(configuration: notebook.configuration) == next ? notebook.configuration : next.configuration)
    reloadKey()
    models = []
    advanced = false
    changed()
  }

  private func reloadKey(force: Bool = false) {
    let origin = try? connection.origin
    guard force || origin != keyOrigin else { return }
    if !force, let previous = keyOrigin {
      keyDrafts[previous] = KeyDraft(value: key, needsRetry: keyReadIssue != nil)
    }
    keyOrigin = origin
    keyReadIssue = nil
    guard let origin else { key = ""; return }
    if !force, let draft = keyDrafts[origin] {
      key = draft.value
      keyReadIssue = draft.needsRetry ? keyUnavailable : nil
      return
    }
    if !force { key = "" }
    do {
      let stored = try KeychainSecretStore.read(origin: origin)
      // An explicit retry must not replace a newly typed key with an older one.
      if !force || key.isEmpty { key = stored }
    } catch { keyReadIssue = keyUnavailable }
  }

  private func changed() {
    saved = false
    resolvedModel = nil
    message = nil
  }

  private func snapshot() throws -> AIConfiguration {
    guard keyReadIssue == nil, try connection.origin == keyOrigin else { throw AIError.configuration }
    var configuration = connection
    configuration.usesAPIKey = provider.requiresAPIKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return configuration
  }

  private func save() {
    do {
      try notebook.saveConnection(snapshot(), key: key.trimmingCharacters(in: .whitespacesAndNewlines))
      saved = true
    } catch { reportConnectionIssue(error) }
  }

  private func run(testing: Bool) {
    do {
      let configuration = try snapshot()
      let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
      busy = true
      message = nil
      task = Task {
        defer { busy = false }
        do {
          if testing {
            let resolved = try await AIModelCatalog().resolve(configuration: configuration, apiKey: secret)
            _ = try await AIClient().complete(configuration: resolved, apiKey: secret,
              messages: [.init(role: .user, content: "Reply with OK.")], context: .build(entries: [], question: ""))
            try Task.checkCancellation()
            resolvedModel = resolved.model
            message = saved ? String(localized: "Connected. No notes were sent for this test.")
              : String(localized: "Connection works. Save to use it in chat. No notes were sent.")
          } else {
            models = try await AIModelCatalog().models(configuration: configuration, apiKey: secret)
            try Task.checkCancellation()
            if models.isEmpty {
              message = String(localized: "No models were returned. Try again or enter a fixed model name.")
            } else if provider == .qwen {
              message = String(localized: "These are documented model aliases. The provider updates latest aliases; account access is checked when you test or send.")
            } else {
              message = String(localized: "Models refreshed. No notes were sent.")
            }
          }
        } catch is CancellationError {} catch {
          if let error = error as? AIError {
            message = NSLocalizedString(error.localizedDescription, comment: "AI connection error")
          } else {
            message = String(localized: "Could not reach this provider. Your settings are kept; check your connection and try again.")
          }
        }
      }
    } catch { reportConnectionIssue(error) }
  }

  private func reportConnectionIssue(_ error: Error) {
    saved = false
    if error is AIError || error is KeychainSecretStore.Failure {
      message = NSLocalizedString(error.localizedDescription, comment: "AI connection error")
    } else {
      message = String(localized: "Could not save the connection. Your inputs are kept; try again.")
    }
  }
}
