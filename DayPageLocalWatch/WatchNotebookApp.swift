import AppIntents
import DayPageCapture
import SwiftUI

@main
struct WatchNotebookApp: App {
  @StateObject private var notebook = WatchNotebook()
  @Environment(\.scenePhase) private var phase
  var body: some Scene {
    WindowGroup {
      WatchCaptureView(notebook: notebook)
        .task { await notebook.activate() }
        .onChange(of: phase) { value in
          if value == .active { Task { await notebook.activate() } }
          if value == .background { notebook.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("daypage.watch.record"))) { _ in
          Task { await notebook.activate() }
        }
    }
  }
}

private struct WatchCaptureView: View {
  @ObservedObject var notebook: WatchNotebook
  private let gold = Color(red: 0.84, green: 0.73, blue: 0.48)
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 14) {
          Text("DAYPAGE").font(.system(.caption2, design: .serif)).tracking(3).foregroundStyle(gold)
          Button {
            if notebook.recording { notebook.stop() } else { Task { await notebook.begin() } }
          } label: {
            Image(systemName: notebook.recording ? "stop.fill" : "mic.fill")
              .font(.system(size: 29, weight: .regular)).foregroundStyle(notebook.recording ? Color.white : gold)
              .frame(width: 88, height: 88)
              .background(notebook.recording ? Color.red.opacity(0.7) : Color(red: 0.12, green: 0.22, blue: 0.19), in: Circle())
              .overlay(Circle().stroke(gold.opacity(0.35), lineWidth: 1))
          }
          .buttonStyle(.plain).disabled(notebook.saving)
          .accessibilityLabel(notebook.recording ? Text("Stop and save recording") : Text("Record a voice note"))
          .accessibilityIdentifier("watch-record")
          if notebook.recording {
            TimelineView(.periodic(from: .now, by: 1)) { context in
              Text(Duration.seconds(max(0, context.date.timeIntervalSince(notebook.started))).formatted(.time(pattern: .minuteSecond)))
                .font(.system(.title3, design: .monospaced)).monospacedDigit()
            }
          }
          Text(notebook.saving ? String(localized: "Keeping your original…") : notebook.message)
            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .accessibilityIdentifier("watch-delivery-status")
          if !notebook.captures.isEmpty {
            Divider().overlay(gold.opacity(0.2))
            ForEach(notebook.captures.prefix(20)) { capture in
              Button { Task { await notebook.play(capture) } } label: {
                HStack(spacing: 8) {
                  Image(systemName: notebook.delivered.contains(capture.id) ? "checkmark.circle" : "arrow.up.circle")
                    .foregroundStyle(gold)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(capture.created, style: .time).font(.body)
                    Text(notebook.delivered.contains(capture.id) ? "In DayPage" : "Saved on Watch")
                      .font(.caption2).foregroundStyle(.secondary)
                  }
                  Spacer(minLength: 0)
                  Image(systemName: "play.fill").font(.caption2).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
              }.buttonStyle(.plain).disabled(notebook.recording || notebook.saving)
            }
          }
        }.padding(.horizontal, 8).padding(.bottom, 12)
      }.background(Color(red: 0.04, green: 0.08, blue: 0.065))
    }
  }
}

struct RecordDayPageWatchNote: AppIntent {
  static var title: LocalizedStringResource = "Record a DayPage voice note"
  static var description = IntentDescription("Open DayPage on your watch and start a local voice recording.")
  static var openAppWhenRun = true
  func perform() async throws -> some IntentResult {
    UserDefaults.standard.set(true, forKey: "watch.startRecording")
    NotificationCenter.default.post(name: Notification.Name("daypage.watch.record"), object: nil)
    return .result()
  }
}

struct WatchNotebookShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: RecordDayPageWatchNote(), phrases: ["Record a note in \(.applicationName)"], shortTitle: "Record a note", systemImageName: "mic")
  }
}
