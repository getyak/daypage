import DayPageCore
import SwiftUI

struct NotebookTimeline: View {
  @EnvironmentObject private var notebook: NotebookModel
  let day: String
  let showAll: () -> Void
  private var entries: [NotebookEntry] {
    notebook.entries.filter { $0.day == day }.sorted {
      if ($0.memo.pinnedAt != nil) != ($1.memo.pinnedAt != nil) { return $0.memo.pinnedAt != nil }
      return $0.memo.created > $1.memo.created
    }
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        if notebook.isLoading {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        } else if let issue = notebook.loadIssue {
          NotebookEmptyState(icon: "exclamationmark.circle", title: "Couldn't read this notebook",
                             detail: issue)
          Button("Try again") { Task { await notebook.refresh() } }.padding(.horizontal, 20)
        } else if entries.isEmpty {
          emptyDay
          if !notebook.entries.isEmpty {
            Text("Recent notes").font(.caption).foregroundStyle(NotebookTheme.muted)
              .padding(.horizontal, 2).padding(.top, 8)
            ForEach(notebook.entries.prefix(3)) { entry in
              VStack(alignment: .leading, spacing: 8) {
                Text(NotebookDate.title(entry.day)).font(.caption2).foregroundStyle(NotebookTheme.muted)
                LocalMemoCard(entry: entry)
              }
            }
          }
        } else {
          ForEach(entries) { entry in LocalMemoCard(entry: entry) }
          HStack(spacing: 7) {
            Text(NotebookTheme.noteCount(entries.count))
            Text("·")
            Text("All saved on this device")
          }
          .font(.caption2).foregroundStyle(NotebookTheme.muted)
          .frame(maxWidth: .infinity).padding(.top, 16).padding(.bottom, 20)
        }
      }
      .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
      .frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier("today-timeline")
    .refreshable { await notebook.refresh() }
    .notebookSurface()
  }

  private var emptyDay: some View {
    VStack(alignment: .leading, spacing: 28) {
      VStack(alignment: .leading, spacing: 12) {
        Text("A little space\nfor whatever comes to mind.")
          .font(NotebookTheme.reading(25)).lineSpacing(6)
        Text("Write a thought, save a photo, or keep a voice note.")
          .font(.subheadline).foregroundStyle(NotebookTheme.muted).lineSpacing(5)
      }
      .padding(.top, 60)
      HStack(spacing: 18) {
        Image(systemName: "text.alignleft")
        Image(systemName: "photo")
        Image(systemName: "waveform")
      }
      .font(.system(size: 19, weight: .light)).foregroundStyle(NotebookTheme.accent.opacity(0.8))
      if !notebook.entries.isEmpty {
        Button(action: showAll) {
          Label("Browse previous notes", systemImage: "books.vertical")
            .font(.subheadline).frame(minHeight: 44)
        }
        .accessibilityIdentifier("browse-previous")
      }
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
  }
}

struct LocalMemoCard: View {
  @EnvironmentObject private var notebook: NotebookModel
  let entry: NotebookEntry
  @State private var deleting = false
  @State private var expanded = false
  @State private var fullHeight: CGFloat = 0
  @State private var visibleHeight: CGFloat = 0
  @State private var shareItems: [Any] = []
  @State private var sharing = false
  @State private var preparingShare = false
  private var tags: [String] { NoteTags.values(in: entry.memo.body) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      NavigationLink(value: entry.id) {
        VStack(alignment: .leading, spacing: 16) {
          if !entry.memo.body.isEmpty {
            Text(entry.memo.body)
              .font(NotebookTheme.reading(17, text: entry.memo.body))
              .lineSpacing(7).lineLimit(expanded ? nil : 6).multilineTextAlignment(.leading)
              .foregroundStyle(NotebookTheme.ink)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background {
                GeometryReader { geometry in
                  Color.clear.onAppear { visibleHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { visibleHeight = $0 }
                }
              }
              .background(alignment: .topLeading) {
                Text(entry.memo.body).font(NotebookTheme.reading(17, text: entry.memo.body))
                  .lineSpacing(7).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background {
                    GeometryReader { geometry in
                      Color.clear.onAppear { fullHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { fullHeight = $0 }
                    }
                  }
                  .hidden().accessibilityHidden(true)
              }
          } else {
            Label(entry.memo.type == .voice ? "Voice note" : "Attachment note",
                  systemImage: entry.memo.type == .voice ? "waveform" : "paperclip")
              .font(NotebookTheme.reading(17)).foregroundStyle(NotebookTheme.secondary)
          }
          HStack(spacing: 8) {
            Text(entry.memo.created, style: .time).font(.caption)
            if entry.memo.pinnedAt != nil { Image(systemName: "pin.fill").font(.caption2) }
            if !entry.namespace.isEmpty { Image(systemName: "tray.and.arrow.down").font(.caption2) }
            Spacer()
          }
          .foregroundStyle(NotebookTheme.muted)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("note-" + entry.memo.id.uuidString)

      if expanded || fullHeight > visibleHeight + 2 {
        Button { expanded.toggle() } label: {
          HStack(spacing: 5) {
            Text(expanded ? "Collapse" : "Read more")
            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
          }
          .font(.caption).foregroundStyle(NotebookTheme.readingAccent)
          .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain).accessibilityIdentifier("expand-note-" + entry.memo.id.uuidString)
      }

      if !entry.memo.attachments.isEmpty { NoteAttachmentStrip(entry: entry) }
      if !tags.isEmpty {
        HStack(spacing: 8) {
          ForEach(tags.prefix(4), id: \.self) { tag in
            Text("#" + tag).font(.caption).foregroundStyle(NotebookTheme.accent)
              .lineLimit(1)
          }
        }
      }
    }
    .padding(17)
    .background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 16))
    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NotebookTheme.line, lineWidth: 0.7) }
    .contextMenu {
      Button {
        Task { await notebook.pin(entry) }
      } label: {
        Label(entry.memo.pinnedAt == nil ? "Pin note" : "Unpin note", systemImage: "pin")
      }
      Button {
        guard !preparingShare else { return }
        preparingShare = true
        Task {
          defer { preparingShare = false }
          do {
            shareItems = try await noteShareItems(entry: entry, store: notebook.store)
            sharing = true
          } catch { notebook.report(error) }
        }
      } label: { Label("Share note", systemImage: "square.and.arrow.up") }
      Button(role: .destructive) { deleting = true } label: {
        Label("Move to Trash", systemImage: "trash")
      }
    }
    .confirmationDialog("Move this note to Trash?", isPresented: $deleting, titleVisibility: .visible) {
      Button("Move to Trash", role: .destructive) { Task { _ = await notebook.trash(entry) } }
      Button("Cancel", role: .cancel) {}
    } message: { Text("You can restore it from Recently Deleted in Archive. Attachments are kept.") }
    .sheet(isPresented: $sharing) { NoteShareSheet(items: shareItems) }
  }
}

struct CaptureDock: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var editing = false
  @State private var chatting = false
  @State private var recording = false
  @State private var recordingDismissed = true
  @State private var capturedVoiceReady = false

  var body: some View {
    VStack(spacing: 10) {
      if notebook.lastDeleted != nil {
        HStack {
          Label("Moved to Trash", systemImage: "trash").font(.caption)
          Spacer()
          Button("Undo") { Task { await notebook.restoreLastDeleted() } }
            .font(.subheadline.weight(.medium)).frame(minHeight: 44)
            .accessibilityIdentifier("undo-trash")
        }
        .padding(.horizontal, 18)
        .background(NotebookTheme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(NotebookTheme.line))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trash-receipt")
      }

      HStack(spacing: typeSize.isAccessibilitySize ? 5 : 12) {
        Button { editing = true } label: {
          Image(systemName: "plus").font(.system(size: 23, weight: .light))
            .frame(width: 44, height: 48)
        }
        .accessibilityLabel("Add an attachment").accessibilityIdentifier("media-add")
        Button { editing = true } label: {
          HStack(spacing: 7) {
            Rectangle().fill(NotebookTheme.faint).frame(width: 2, height: 17)
            Text(notebook.draft.isEmpty && notebook.pendingAssets.isEmpty ? "Capture a thought…" : "Continue your draft")
              .font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
          }
          .frame(minHeight: 48).contentShape(Rectangle())
        }
        .accessibilityLabel("Write a note").accessibilityIdentifier("new-note")
        Button {
          capturedVoiceReady = false
          recordingDismissed = false
          recording = true
        } label: {
          Image(systemName: "mic").font(.system(size: 23, weight: .regular))
            .foregroundStyle(.white).frame(width: 48, height: 48)
            .background(
              LinearGradient(colors: [Color(red: 0.79, green: 0.43, blue: 0.18),
                                      Color(red: 0.65, green: 0.30, blue: 0.08)],
                             startPoint: .topLeading, endPoint: .bottomTrailing),
              in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            .shadow(color: NotebookTheme.accent.opacity(0.20), radius: 10, x: 0, y: 3)
        }
        .disabled(!notebook.canRecordVoice)
        .accessibilityLabel("Record a voice note").accessibilityIdentifier("dock-voice")
        Button { chatting = true } label: {
          Image(systemName: "sparkles").font(.system(size: 21, weight: .regular))
            .frame(width: 44, height: 48)
        }
        .accessibilityLabel("Chat with notes").accessibilityIdentifier("chat-with-notes")
      }
      .foregroundStyle(NotebookTheme.muted)
      .buttonStyle(.plain)
      .padding(8).padding(.horizontal, 3)
      .background {
        if reduceTransparency {
          Capsule().fill(NotebookTheme.accentSoft)
        } else {
          Capsule().fill(.regularMaterial)
            .overlay(Capsule().fill(NotebookTheme.accentSoft.opacity(0.55)))
        }
      }
      .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 0.7))
      .shadow(color: .black.opacity(0.09), radius: 20, x: 0, y: 10)
      .disabled(notebook.isLoading)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("capture-dock")
      if !notebook.canRecordVoice {
        Text("Free some draft attachment space to record audio.")
          .font(.caption2).foregroundStyle(NotebookTheme.muted)
      }
    }
    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 10)
    .frame(maxWidth: 650).frame(maxWidth: .infinity)
    .background(LinearGradient(colors: [NotebookTheme.paper.opacity(0), NotebookTheme.paper],
                               startPoint: .top, endPoint: .bottom))
    .sheet(isPresented: $editing) { NoteEditor() }
    .sheet(isPresented: $chatting) { NoteChatView(selectedIDs: nil) }
    .sheet(isPresented: $recording, onDismiss: {
      recordingDismissed = true
      if capturedVoiceReady { editing = true; capturedVoiceReady = false }
    }) {
      VoiceCaptureView { data, duration in
          let accepted = await notebook.addCaptureAsset(data: data, filename: "Voice note.m4a", kind: "audio", duration: duration)
          guard accepted else { return false }
          capturedVoiceReady = true
          if recordingDismissed { editing = true; capturedVoiceReady = false }
          recording = false
          return true
      }
    }
  }
}

struct NotebookEmptyState: View {
  let icon: String
  let title: LocalizedStringKey
  let detail: String
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(NotebookTheme.muted)
      Text(title).font(NotebookTheme.reading(22))
      Text(detail).font(.subheadline).foregroundStyle(NotebookTheme.muted)
        .multilineTextAlignment(.center).lineSpacing(4)
    }
    .padding(28).frame(maxWidth: .infinity).padding(.vertical, 40)
  }
}

enum NoteTags {
  static func values(in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_/])#([\p{L}\p{N}_-]+)"#) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return Array(Set(regex.matches(in: text, range: range).compactMap { result in
      Range(result.range(at: 1), in: text).map { String(text[$0]) }
    })).sorted()
  }
}
