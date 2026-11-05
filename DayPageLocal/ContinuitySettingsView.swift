import DayPageCore
import SwiftUI

struct ContinuitySettingsView: View {
  @EnvironmentObject private var cloud: CloudContinuity
  @EnvironmentObject private var watch: WatchPhoneBridge
  var body: some View {
    Form {
      Section("Apple Watch") {
        Label("Record on your wrist", systemImage: "applewatch")
        Text("Open DayPage on Apple Watch, or use its Record a note shortcut. Tap to record and tap again to save. Original audio stays on Watch until DayPage confirms it is saved.")
          .font(.footnote).foregroundStyle(.secondary)
        Text(watch.status).font(.footnote).foregroundStyle(.secondary)
          .accessibilityIdentifier("watch-phone-status")
        Toggle("Transcribe Watch audio on this iPhone", isOn: Binding(get: { watch.transcribes }, set: { value in
          Task { await watch.setTranscribes(value) }
        })).accessibilityIdentifier("watch-local-transcription")
        Text("Uses on-device speech recognition while DayPage is open. Unsupported languages keep the audio. No audio is sent to a transcription service.")
          .font(.caption).foregroundStyle(.secondary)
      }.listRowBackground(NotebookTheme.card)
      Section("iCloud Drive") {
        Toggle("Sync notes and attachments", isOn: Binding(get: { cloud.enabled }, set: { value in
          Task { await cloud.setEnabled(value) }
        })).disabled(cloud.working && !cloud.enabled).accessibilityIdentifier("icloud-enabled")
        Text("Enabling copies this device’s notes and attachments to your current iCloud account and brings its DayPage notes here. iCloud uses Apple’s servers. Recording and editing keep working offline.")
          .font(.caption).foregroundStyle(.secondary)
        Text(cloud.status).font(.footnote).foregroundStyle(.secondary)
          .accessibilityIdentifier("icloud-status")
        if cloud.working { ProgressView() }
        if let last = cloud.lastExchange {
          HStack { Text("Last local exchange"); Spacer(); Text(last, style: .relative).foregroundStyle(.secondary) }
        }
        Button("Sync now") { Task { await cloud.exchange() } }
          .disabled(!cloud.enabled || cloud.working).accessibilityIdentifier("icloud-sync-now")
      }.listRowBackground(NotebookTheme.card)
      Section("Recover notes") {
        NavigationLink("Browse saved versions") { SavedNoteVersionsView() }
          .disabled(!cloud.enabled).accessibilityIdentifier("icloud-versions")
        Text("Versions preserve notes and their attachments after sync is enabled. Recovery adds a separate copy. Chats, note relationships and action history, model keys, unfinished drafts and notes already in Recently Deleted are excluded. Export notebook files in Settings for a complete file copy.")
          .font(.caption).foregroundStyle(.secondary)
        Text("Turning sync off or signing out of iCloud keeps this device’s downloaded notes. Concurrent edits keep both copies. iCloud upload and delivery timing are managed by the system.")
          .font(.caption).foregroundStyle(.secondary)
      }.listRowBackground(NotebookTheme.card)
    }
    .navigationTitle("Devices & iCloud").navigationBarTitleDisplayMode(.inline)
    .scrollContentBackground(.hidden).notebookSurface()
  }
}

private struct SavedNoteVersionsView: View {
  @EnvironmentObject private var cloud: CloudContinuity
  @State private var limit = 30
  var body: some View {
    List {
      if cloud.history.isEmpty {
        Text("Saved versions appear after the first successful exchange.").foregroundStyle(.secondary)
      }
      ForEach(cloud.history.prefix(limit)) { version in
        VStack(alignment: .leading, spacing: 8) {
          Text(version.day ?? "").font(.caption).foregroundStyle(.secondary)
          Text(version.preview.isEmpty ? String(localized: "Voice note") : version.preview).lineLimit(3)
          Button("Recover a copy") { Task { await cloud.restore(version.id) } }
            .disabled(cloud.working).accessibilityIdentifier("icloud-restore-" + version.id)
        }.padding(.vertical, 4).listRowBackground(NotebookTheme.card)
      }
      if cloud.history.count > limit { Button("Show more") { limit += 30 } }
      Text(cloud.status).font(.footnote).foregroundStyle(.secondary)
    }
    .navigationTitle("Saved versions").navigationBarTitleDisplayMode(.inline)
    .scrollContentBackground(.hidden).notebookSurface()
  }
}
