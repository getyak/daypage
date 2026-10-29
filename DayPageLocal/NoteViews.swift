import DayPageCore
import QuickLook
import SwiftUI

struct NoteEditor: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dismiss) private var dismiss
  var entry: NotebookEntry? = nil
  @State private var text = ""
  @State private var saving = false

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Label("Saved only on this device", systemImage: "internaldrive")
          .font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $text)
          .font(NotebookTheme.reading(text: text)).lineSpacing(6)
          .scrollContentBackground(.hidden)
          .accessibilityLabel("Note text")
          .accessibilityIdentifier("note-editor")
      }
      .padding(24)
      .notebookSurface()
      .navigationTitle(entry == nil ? "Write a note" : "Edit note")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }.disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            saving = true
            Task {
              if await notebook.save(body: text, editing: entry) { dismiss() }
              saving = false
            }
          } label: {
            if saving { ProgressView() } else { Text("Save").bold() }
          }
          .disabled(
            saving
              || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && entry?.memo.attachments.isEmpty != false)
          )
          .accessibilityIdentifier("save-note")
        }
      }
    }
    .interactiveDismissDisabled(saving)
    .onAppear { text = entry?.memo.body ?? notebook.draft }
    .onChange(of: text) { value in
      if entry == nil {
        notebook.draft = value
        notebook.saveDraft()
      }
    }
  }
}

struct NoteDetailView: View {
  @EnvironmentObject private var notebook: NotebookModel
  let entry: NotebookEntry
  @State private var editing = false
  @State private var chatting = false
  @State private var preview: URL?
  private var current: NotebookEntry {
    notebook.entries.first(where: { $0.id == entry.id }) ?? entry
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        Text(current.memo.created.formatted(date: .long, time: .shortened))
          .font(.caption).foregroundStyle(.secondary)
        Text(current.memo.body)
          .font(NotebookTheme.reading(20, text: current.memo.body)).lineSpacing(8)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("note-original")
        if !current.memo.attachments.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            Text("Attachments").font(.headline)
            ForEach(Array(current.memo.attachments.enumerated()), id: \.offset) { _, attachment in
              Button {
                Task {
                  do {
                    preview = try await notebook.store.assetURL(attachment.file, for: current)
                  } catch { notebook.report(error) }
                }
              } label: {
                Label(
                  attachment.file.components(separatedBy: "/").last ?? attachment.file,
                  systemImage: attachment.kind == "photo" ? "photo" : "waveform"
                )
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              }
              .buttonStyle(.bordered)
            }
          }
        }
        Button {
          chatting = true
        } label: {
          Label("Chat about this note", systemImage: "bubble.left.and.bubble.right").frame(
            minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("chat-about-note")
      }
      .padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
    .notebookSurface()
    .navigationTitle("Note")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button("Edit") { editing = true }.accessibilityIdentifier("edit-note")
      }
    }
    .quickLookPreview($preview)
    .sheet(isPresented: $editing) { NoteEditor(entry: current) }
    .sheet(isPresented: $chatting) { NoteChatView(selectedIDs: [current.id]) }
  }
}
