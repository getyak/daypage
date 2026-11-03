import AVFoundation
import DayPageCore
import SwiftUI

/// Save only writes local preferences/Keychain. Preview uses the current draft and a synthetic sentence.
struct SpeechSettingsView: View {
  private let defaults: UserDefaults
  @StateObject private var playback: SpeechPlayback
  @State private var preferences = SpeechPreferences()
  @State private var draft = SpeechChannel.system
  @State private var key = ""
  @State private var keyAccount: String?
  @State private var keyDrafts: [String: KeyDraft] = [:]
  @State private var keyReadIssue: String?
  @State private var message: String?
  @State private var initialized = false
  @State private var saved = false
  @State private var loadedProvider = SpeechProvider.system
  private struct KeyDraft { var value: String; var readFailed: Bool }

  init(defaults: UserDefaults) {
    self.defaults = defaults
    _playback = StateObject(wrappedValue: SpeechPlayback(defaults: defaults))
  }

  private var canSave: Bool {
    (try? draft.validated()) != nil && (!draft.requiresAuthentication
      || (keyReadIssue == nil && keyAccount == (try? draft.credentialAccount)
        && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
  }
  private var active: Bool { playback.isActive(id: "speech-preview") }
  private var voices: [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }
  }

  var body: some View {
    Form {
      Section {
        ForEach(preferences.channels) { channel in
          Button { edit(channel) } label: {
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 3) {
                Text(channel.provider == .system && channel.name == SpeechProvider.system.name
                  ? String(localized: "System speech") : channel.name)
                  .foregroundStyle(NotebookTheme.ink)
                if channel.provider != .system {
                  Text(LocalizedStringKey(channel.provider.name)).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              if channel.id == preferences.selectedChannelID {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(NotebookTheme.accent)
              }
              if channel.id == draft.id {
                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
              }
            }.frame(minHeight: 44).contentShape(Rectangle())
          }
          .accessibilityIdentifier("speech-channel-" + channel.id)
          .accessibilityAddTraits(channel.id == preferences.selectedChannelID ? .isSelected : [])
          .accessibilityValue(channel.id == preferences.selectedChannelID ? String(localized: "Selected") : "")
        }
        Button {
          guard preferences.channels.count < 20 else { return }
          edit(SpeechChannel(name: String(localized: "New speech channel"), provider: .openAI))
        } label: { Label("Add speech channel", systemImage: "plus") }
          .disabled(preferences.channels.count >= 20).accessibilityIdentifier("speech-add-channel")
      } header: { Text("Speech channels") } footer: {
        Text("The checkmark is your saved playback channel. Saving an edited channel selects it for the next Play.")
      }
      .listRowBackground(NotebookTheme.card)

      Section("Edit channel") {
        TextField("Channel name", text: $draft.name).accessibilityIdentifier("speech-channel-name")
        Picker("Provider", selection: $draft.provider) {
          ForEach(SpeechProvider.allCases) { provider in
            Text(LocalizedStringKey(provider.name)).tag(provider)
          }
        }.disabled(draft.id == "system").accessibilityIdentifier("speech-provider")
        if draft.provider == .system {
          Picker("Voice", selection: $draft.voice) {
            Text("Automatic").tag("")
            ForEach(voices, id: \.identifier) { voice in
              Text(voice.name + " · " + voice.language).tag(voice.identifier)
            }
            if !draft.voice.isEmpty && !voices.contains(where: { $0.identifier == draft.voice }) {
              Text("Saved voice is unavailable").tag(draft.voice)
            }
          }.accessibilityIdentifier("speech-system-voice")
          Text("Uses a voice installed on this device. No API key or speech service is needed.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          TextField("Service address", text: $draft.baseURL)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            .accessibilityIdentifier("speech-base-url")
          TextField("Model", text: $draft.model)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("speech-model")
          TextField(draft.provider == .elevenLabs ? "Voice ID" : "Voice", text: $draft.voice)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("speech-voice")
          if draft.provider == .openAICompatible {
            Toggle("Use API key", isOn: $draft.usesAPIKey)
              .accessibilityIdentifier("speech-requires-key")
          }
          if draft.requiresAuthentication {
            SecureField("API key", text: $key)
              .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
              .accessibilityIdentifier("speech-api-key")
          }
          Toggle("Allow local HTTP", isOn: $draft.allowsLocalHTTP)
            .accessibilityIdentifier("speech-local-http")
          if draft.requiresAuthentication, let keyReadIssue {
            Text(keyReadIssue).font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("speech-key-error")
            Button("Retry saved key") { reloadKey(force: true) }
              .accessibilityIdentifier("speech-key-retry")
          }
          if draft.requiresAuthentication {
            Text("Keys stay in this device’s Keychain, separately for each channel, provider and service address.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        HStack {
          Text("Speed")
          Spacer()
          Text(draft.speed.formatted(.number.precision(.fractionLength(2))) + "×")
            .monospacedDigit().foregroundStyle(.secondary)
        }
        Slider(value: $draft.speed, in: draft.provider.speedRange, step: 0.05)
          .accessibilityLabel("Speech speed").accessibilityIdentifier("speech-speed")
      }
      .listRowBackground(NotebookTheme.card)
      .disabled(active)

      Section {
        Button(action: save) {
          Label(saved ? "Speech channel saved" : "Save and select channel", systemImage: saved ? "checkmark" : "checkmark.circle")
        }.disabled(!canSave || active).accessibilityIdentifier("speech-save-channel")
        Button {
          guard canSave else { return }
          message = nil
          playback.preview(String(localized: "This is a short DayPage speech sample. Your notes stay private during this test."),
            channel: draft, apiKey: key)
        } label: {
          HStack {
            Label("Preview voice without notes", systemImage: "play.circle")
            Spacer()
            if playback.isPreparing { ProgressView() }
          }
        }.disabled(!canSave || active).accessibilityIdentifier("speech-preview")
        if active {
          if !playback.isPreparing {
            Button(playback.isPaused ? "Resume" : "Pause") {
              if playback.isPaused { playback.resume() } else { playback.pause() }
            }.accessibilityIdentifier("speech-pause")
          }
          Button("Stop speech", role: .cancel) { playback.stop() }
            .accessibilityIdentifier("speech-stop")
        }
        if let status = playback.status {
          Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("speech-status")
        }
        if let error = playback.error {
          Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("speech-error")
        }
        if let message {
          Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("speech-save-status")
        }
      } footer: {
        Text("Save works offline. Preview sends only this fixed sample to the edited channel. Your notes are sent only when you tap Play.")
      }
      .listRowBackground(NotebookTheme.card)

      if draft.id != "system", preferences.channels.contains(where: { $0.id == draft.id }) {
        Section {
          Button("Delete speech channel", role: .destructive, action: delete)
            .disabled(active).accessibilityIdentifier("speech-delete")
        }.listRowBackground(NotebookTheme.card)
      }
    }
    .accessibilityIdentifier("speech-settings-form")
    .navigationTitle("Read aloud").navigationBarTitleDisplayMode(.inline)
    .scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).notebookSurface()
    .onAppear(perform: load)
    .onDisappear { playback.stop() }
    .onChange(of: draft.provider) { _ in providerChanged() }
    .onChange(of: draft.baseURL) { _ in reloadKey(); saved = false }
    .onChange(of: draft.usesAPIKey) { _ in reloadKey(force: draft.requiresAuthentication); saved = false }
    .onChange(of: draft) { _ in saved = false }
    .onChange(of: key) { _ in saved = false }
  }

  private func load() {
    guard !initialized else { return }
    initialized = true
    do { preferences = try SpeechPreferencesStore(defaults: defaults).loadValidated() }
    catch { message = localized(error) }
    edit(preferences.selectedChannel ?? .system)
  }
  private func edit(_ channel: SpeechChannel) {
    playback.stop()
    cacheKey()
    // Loading a saved provider must not replace its saved address/model/voice with defaults.
    loadedProvider = channel.provider
    draft = channel
    keyAccount = nil
    key = ""
    keyReadIssue = nil
    reloadKey()
    saved = false
  }
  private func providerChanged() {
    guard loadedProvider != draft.provider else { return }
    loadedProvider = draft.provider
    cacheKey()
    let replacement = SpeechChannel(id: draft.id, name: draft.name, provider: draft.provider)
    draft = replacement
    reloadKey()
    saved = false
  }
  private func cacheKey() {
    if let keyAccount { keyDrafts[keyAccount] = KeyDraft(value: key, readFailed: keyReadIssue != nil) }
  }
  private func reloadKey(force: Bool = false) {
    guard draft.requiresAuthentication, let account = try? draft.credentialAccount else {
      cacheKey(); keyAccount = nil; key = ""; keyReadIssue = nil
      return
    }
    guard force || keyAccount != account else { return }
    cacheKey()
    keyAccount = account
    if !force, let cached = keyDrafts[account] {
      key = cached.value
      keyReadIssue = cached.readFailed ? localized(SpeechError.keychain) : nil
      return
    }
    let typed = keyDrafts[account]?.value ?? ""
    key = typed
    do {
      let stored = try SpeechSecretStore.read(channel: draft)
      if typed.isEmpty { key = stored }
      keyReadIssue = nil
    } catch { keyReadIssue = localized(error) }
  }
  private func save() {
    playback.stop()
    message = nil
    do {
      guard canSave else { throw SpeechError.configuration }
      _ = try draft.validated()
      if draft.requiresAuthentication { try SpeechSecretStore.save(key, channel: draft) }
      var updated = preferences
      if let index = updated.channels.firstIndex(where: { $0.id == draft.id }) { updated.channels[index] = draft }
      else { updated.channels.append(draft) }
      updated.selectedChannelID = draft.id
      try SpeechPreferencesStore(defaults: defaults).save(updated)
      preferences = updated
      cacheKey()
      saved = true
      message = String(localized: "Speech channel saved")
    } catch { message = localized(error) }
  }
  private func delete() {
    message = nil
    do {
      let stored = preferences.channels.first { $0.id == draft.id }
      if let stored { try SpeechSecretStore.remove(channel: stored) }
      var updated = preferences
      updated.channels.removeAll { $0.id == draft.id }
      if updated.selectedChannelID == draft.id {
        if !updated.channels.contains(where: { $0.id == "system" }) { updated.channels.insert(.system, at: 0) }
        updated.selectedChannelID = "system"
      }
      try SpeechPreferencesStore(defaults: defaults).save(updated)
      preferences = updated
      edit(updated.selectedChannel ?? .system)
    } catch { message = localized(error) }
  }
  private func localized(_ error: Error) -> String {
    let speech = error as? SpeechError ?? .configuration
    return NSLocalizedString(speech.localizedDescription, comment: "Speech settings error")
  }
}
