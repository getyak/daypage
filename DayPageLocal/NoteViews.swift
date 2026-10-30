import AVFoundation
import DayPageCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct NoteEditor: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dismiss) private var dismiss
  let entry: NotebookEntry?
  @State private var text = ""
  @State private var loaded = false
  @State private var saving = false
  @State private var importing = false
  @State private var mediaSheet: CaptureSheet?
  @State private var selectingFiles = false
  @State private var selectedPhotos: [PhotosPickerItem] = []
  @State private var confirmingDiscard = false
  @State private var mediaError: String?
  @State private var showSettingsRecovery = false
  @State private var editConflict = false
  @FocusState private var focused: Bool
  @SceneStorage private var hasEditingDraft: Bool
  @SceneStorage private var editingDraftBody: String
  @SceneStorage private var editingDraftBase: String
  private let opened = Date()

  init(entry: NotebookEntry? = nil) {
    self.entry = entry
    let key = "notebook.editor.edit." + (entry?.id ?? "new")
    _hasEditingDraft = SceneStorage(wrappedValue: false, key + ".exists")
    _editingDraftBody = SceneStorage(wrappedValue: "", key + ".body")
    _editingDraftBase = SceneStorage(wrappedValue: "", key + ".base")
  }

  private enum CaptureSheet: String, Identifiable {
    case camera, voice
    var id: String { rawValue }
  }
  private var busy: Bool { saving || notebook.isSaving || importing }
  private var canSave: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || (entry.map { !$0.memo.attachments.isEmpty } ?? !notebook.pendingAssets.isEmpty)
  }
  private var hasChanges: Bool {
    if let entry { return text != entry.memo.body }
    return !text.isEmpty || !notebook.pendingAssets.isEmpty
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 0) {
        timestamp
        ZStack(alignment: .topLeading) {
          if text.isEmpty {
            Text("What would you like to remember?")
              .font(NotebookTheme.reading(18)).foregroundStyle(NotebookTheme.faint)
              .padding(.horizontal, 5).padding(.top, 8).allowsHitTesting(false)
          }
          TextEditor(text: $text)
            .font(NotebookTheme.reading(18, text: text)).lineSpacing(6)
            .foregroundStyle(NotebookTheme.ink).scrollContentBackground(.hidden)
            .focused($focused).disabled(saving || notebook.isSaving)
            .accessibilityLabel("Note text").accessibilityIdentifier("note-editor")
        }
        .frame(minHeight: 160)
        if let entry, !entry.memo.attachments.isEmpty {
          NoteAttachmentStrip(entry: entry).padding(.vertical, 12)
        } else if entry == nil, !notebook.pendingAssets.isEmpty {
          PendingAttachmentStrip(assets: notebook.pendingAssets, disabled: busy) { id in
            importing = true
            Task {
              await notebook.removeCaptureAsset(id)
              importing = false
            }
          }.padding(.vertical, 12)
        }
        if importing {
          ProgressView("Adding attachment…").font(.caption)
            .padding(.vertical, 10).accessibilityIdentifier("attachment-importing")
        }
        if let error = mediaError ?? notebook.error {
          VStack(alignment: .leading, spacing: 6) {
            Text(error).font(.caption).foregroundStyle(.red)
            if showSettingsRecovery {
              Button("Open Settings") { openAppSettings() }.font(.caption).frame(minHeight: 44)
            }
          }.padding(.vertical, 8)
        }
        if editConflict, let entry {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "The saved note changed while this draft was closed. Review it before replacing it."
            )
            .font(.caption).foregroundStyle(NotebookTheme.muted)
            DisclosureGroup("Latest saved note") {
              ScrollView { Text(entry.memo.body).font(.subheadline).textSelection(.enabled) }
                .frame(maxHeight: 120)
            }.font(.subheadline)
            Button("Use this draft") {
              editingDraftBase = entry.memo.body
              editConflict = false
            }.font(.subheadline).frame(minHeight: 44)
          }.padding(.vertical, 8)
        }
        if entry == nil {
          captureRail
          if !notebook.canRecordVoice {
            Text("Free some draft attachment space to record audio.")
              .font(.caption).foregroundStyle(NotebookTheme.muted).padding(.top, 6)
          }
        }
      }
      .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 8)
      .notebookSurface()
      .navigationTitle(entry == nil ? "Write a note" : "Edit note")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            focused = false
            dismiss()
          } label: {
            Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 44)
          }
          .disabled(busy).accessibilityLabel("Collapse and keep draft").accessibilityIdentifier(
            "collapse-note")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(action: save) {
            if saving || notebook.isSaving {
              ProgressView()
            } else {
              Text("Save").fontWeight(.semibold)
            }
          }.disabled(busy || !canSave || editConflict).accessibilityIdentifier("save-note")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Menu {
            Button(role: .destructive) {
              confirmingDiscard = true
            } label: {
              Label("Discard draft", systemImage: "trash")
            }.disabled(!hasChanges).accessibilityIdentifier("discard-note")
          } label: {
            Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
          }.disabled(busy).accessibilityLabel("Draft options")
        }
      }
    }
    .tint(NotebookTheme.accent)
    .presentationDetents([.large]).presentationDragIndicator(.visible)
    .interactiveDismissDisabled(busy)
    .onAppear(perform: loadDraft)
    .onChange(of: text) { value in
      guard loaded else { return }
      if let entry {
        if value != entry.memo.body || hasEditingDraft {
          hasEditingDraft = true
          editingDraftBody = value
        }
      } else {
        notebook.draft = value
        notebook.saveDraft()
      }
    }
    .onChange(of: selectedPhotos) { photos in
      guard !photos.isEmpty else { return }
      importing = true
      mediaError = nil
      Task {
        defer {
          importing = false
          selectedPhotos = []
        }
        for item in photos {
          do {
            guard let photo = try await item.loadTransferable(type: PickedNotePhoto.self) else {
              throw CaptureError.unreadableFile
            }
            await notebook.addCaptureAsset(
              data: photo.data, filename: photo.filename, kind: "photo")
          } catch { mediaError = error.localizedDescription }
        }
      }
    }
    .sheet(item: $mediaSheet) { destination in
      switch destination {
      case .camera:
        NoteCameraPicker { image in importCameraImage(image) }.ignoresSafeArea()
      case .voice:
        VoiceCaptureView { data, duration in
          importing = true
          let accepted = await notebook.addCaptureAsset(
              data: data, filename: "Voice-\(UUID().uuidString.prefix(8)).m4a", kind: "audio",
              duration: duration)
          importing = false
          return accepted
        }
      }
    }
    .fileImporter(
      isPresented: $selectingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls): importFiles(urls)
      case .failure(let error): mediaError = error.localizedDescription
      }
    }
    .confirmationDialog(
      "Discard this draft?", isPresented: $confirmingDiscard, titleVisibility: .visible
    ) {
      Button("Discard draft", role: .destructive) {
        saving = true
        Task {
          defer { saving = false }
          if entry == nil {
            await notebook.discardDraft()
            guard notebook.draft.isEmpty, notebook.pendingAssets.isEmpty else { return }
          } else {
            hasEditingDraft = false
            editingDraftBody = ""
            editingDraftBase = ""
          }
          dismiss()
        }
      }.accessibilityIdentifier("confirm-discard-note")
      Button("Keep writing", role: .cancel) {}
    } message: {
      Text("This removes the draft and its unsaved attachments.")
    }
  }

  private var timestamp: some View {
    HStack(spacing: 6) {
      Text((entry?.memo.created ?? opened).formatted(date: .abbreviated, time: .shortened))
        .font(NotebookTheme.mono(11)).foregroundStyle(NotebookTheme.muted)
      Spacer()
      if entry == nil, hasChanges {
        Text("Draft").font(.caption2).foregroundStyle(NotebookTheme.muted)
      }
    }.padding(.bottom, 12)
  }

  private var captureRail: some View {
    HStack(spacing: 8) {
      PhotosPicker(
        selection: $selectedPhotos,
        maxSelectionCount: min(6, max(1, 10 - notebook.pendingAssets.count)), matching: .images,
        preferredItemEncoding: .current
      ) {
        railIcon("photo", label: "Photos")
      }.disabled(notebook.pendingAssets.count >= 10).accessibilityIdentifier("capture-photo")
      Button(action: requestCamera) { railIcon("camera", label: "Camera") }.accessibilityIdentifier(
        "capture-camera")
      Button {
        focused = false
        selectingFiles = true
      } label: {
        railIcon("paperclip", label: "Files")
      }.accessibilityIdentifier("capture-file")
      Button {
        focused = false
        mediaSheet = .voice
      } label: {
        railIcon("mic", label: "Voice")
      }.disabled(!notebook.canRecordVoice).accessibilityIdentifier("capture-voice")
      Spacer(minLength: 0)
    }
    .foregroundStyle(NotebookTheme.muted).buttonStyle(.plain).disabled(busy)
    .padding(.top, 8)
    .overlay(alignment: .top) { Rectangle().fill(NotebookTheme.line).frame(height: 1) }
    .accessibilityElement(children: .contain).accessibilityIdentifier("media-add")
  }
  private func railIcon(_ symbol: String, label: LocalizedStringKey) -> some View {
    VStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 18))
      Text(label).font(.caption2)
    }.frame(minWidth: 48, minHeight: 48).contentShape(Rectangle())
  }
  private func loadDraft() {
    guard !loaded else { return }
    if let entry {
      if hasEditingDraft {
        editConflict = editingDraftBase != entry.memo.body
      } else {
        editingDraftBase = entry.memo.body
      }
    }
    text = entry.map { hasEditingDraft ? editingDraftBody : $0.memo.body } ?? notebook.draft
    loaded = true
    focused = true
  }
  private func save() {
    guard !busy, canSave, !editConflict else { return }
    saving = true
    mediaError = nil
    focused = false
    Task {
      if await notebook.save(body: text, editing: entry) {
        if entry != nil {
          hasEditingDraft = false
          editingDraftBody = ""
          editingDraftBase = ""
        }
        dismiss()
      }
      saving = false
    }
  }
  private func requestCamera() {
    focused = false
    mediaError = nil
    showSettingsRecovery = false
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      mediaError = CaptureError.unavailableCamera.localizedDescription
      return
    }
    Task {
      let authorized: Bool
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized: authorized = true
      case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
      default: authorized = false
      }
      if authorized {
        mediaSheet = .camera
      } else {
        mediaError = String(
          localized: "Allow camera access in Settings, or choose a photo from your library.")
        showSettingsRecovery = true
      }
    }
  }
  private func importCameraImage(_ image: UIImage) {
    importing = true
    mediaError = nil
    Task {
      defer { importing = false }
      let data = await Task.detached(priority: .userInitiated) {
        image.jpegData(compressionQuality: 0.88)
      }.value
      guard let data else {
        mediaError = CaptureError.unreadableFile.localizedDescription
        return
      }
      guard data.count <= CaptureFileReader.maximumBytes else {
        mediaError = CaptureError.tooLarge.localizedDescription
        return
      }
      await notebook.addCaptureAsset(
        data: data, filename: "Photo-\(UUID().uuidString.prefix(8)).jpg", kind: "photo")
    }
  }
  private func importFiles(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    importing = true
    mediaError = nil
    Task {
      defer { importing = false }
      for url in urls {
        do {
          let data = try await CaptureFileReader.coordinatedRead(url)
          let type = UTType(filenameExtension: url.pathExtension)
          let kind =
            type?.conforms(to: .image) == true
            ? "photo" : type?.conforms(to: .audio) == true ? "audio" : "file"
          await notebook.addCaptureAsset(data: data, filename: url.lastPathComponent, kind: kind)
        } catch { mediaError = error.localizedDescription }
      }
    }
  }
}

struct NoteDetailView: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dismiss) private var dismiss
  let entry: NotebookEntry
  @State private var destination: DetailSheet?
  @State private var confirmingTrash = false
  @State private var working = false
  @State private var shareItems: [Any] = []
  private enum DetailSheet: String, Identifiable {
    case edit, chat, share
    var id: String { rawValue }
  }
  private var current: NotebookEntry {
    notebook.entries.first(where: { $0.id == entry.id }) ?? entry
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(spacing: 8) {
          Text(current.memo.created.formatted(date: .abbreviated, time: .shortened))
          if current.memo.pinnedAt != nil {
            Image(systemName: "pin.fill").accessibilityLabel("Pinned")
          }
        }.font(NotebookTheme.mono(11)).foregroundStyle(NotebookTheme.muted)
        if !current.memo.body.isEmpty {
          NoteMarkdownBody(text: current.memo.body).accessibilityIdentifier("note-original")
        }
        if !current.memo.attachments.isEmpty { NoteAttachmentStrip(entry: current) }
        Button {
          destination = .chat
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(NotebookTheme.accent)
            Text("Chat about this note").font(.subheadline)
            Spacer()
            Image(systemName: "chevron.right").font(.caption)
          }
          .foregroundStyle(NotebookTheme.ink).padding(16)
          .background(NotebookTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12)).frame(
            minHeight: 44)
        }.buttonStyle(.plain).disabled(working).accessibilityIdentifier("chat-about-note")
        metadata
      }
      .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 40)
      .frame(maxWidth: 680).frame(maxWidth: .infinity)
    }
    .notebookSurface().tint(NotebookTheme.accent)
    .navigationTitle("Note").navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Button("Edit") { destination = .edit }.disabled(working).accessibilityIdentifier(
          "edit-note")
        Menu {
          Button {
            working = true
            Task {
              await notebook.pin(current)
              working = false
            }
          } label: {
            Label(
              current.memo.pinnedAt == nil ? "Pin note" : "Unpin note",
              systemImage: current.memo.pinnedAt == nil ? "pin" : "pin.slash")
          }.accessibilityIdentifier("pin-note")
          Button(action: share) { Label("Share note", systemImage: "square.and.arrow.up") }
            .accessibilityIdentifier("share-note")
          Divider()
          Button(role: .destructive) {
            confirmingTrash = true
          } label: {
            Label("Move to Trash", systemImage: "trash")
          }.accessibilityIdentifier("trash-note")
        } label: {
          if working {
            ProgressView().frame(width: 44, height: 44)
          } else {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
          }
        }.disabled(working).accessibilityLabel("Note actions")
      }
    }
    .sheet(item: $destination) { destination in
      switch destination {
      case .edit: NoteEditor(entry: current)
      case .chat: NoteChatView(selectedIDs: [current.id])
      case .share: NoteShareSheet(items: shareItems)
      }
    }
    .confirmationDialog(
      "Move this note to Trash?", isPresented: $confirmingTrash, titleVisibility: .visible
    ) {
      Button("Move to Trash", role: .destructive) {
        working = true
        Task {
          if await notebook.trash(current) { dismiss() }
          working = false
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The note and its attachments are kept. You can restore it from Trash.")
    }
  }
  private var metadata: some View {
    VStack(alignment: .leading, spacing: 12) {
      Rectangle().fill(NotebookTheme.line).frame(height: 1)
      HStack {
        Label(typeName, systemImage: typeSymbol)
        Spacer()
        Text(current.day)
      }
      .font(.caption).foregroundStyle(NotebookTheme.muted)
      Text(current.memo.created.formatted(date: .long, time: .shortened))
        .font(.caption2).foregroundStyle(NotebookTheme.muted)
    }
  }
  private var typeName: LocalizedStringKey {
    switch current.memo.type {
    case .text: return "Text note"
    case .voice: return "Voice note"
    case .photo: return "Photo note"
    case .location: return "Place note"
    case .mixed: return "Mixed note"
    }
  }
  private var typeSymbol: String {
    switch current.memo.type {
    case .text: return "text.alignleft"
    case .voice: return "waveform"
    case .photo: return "photo"
    case .location: return "mappin"
    case .mixed: return "paperclip"
    }
  }
  private func share() {
    working = true
    let entry = current
    Task {
      defer { working = false }
      do {
        shareItems = try await noteShareItems(entry: entry, store: notebook.store)
        destination = .share
      } catch { notebook.report(error) }
    }
  }
}

/// Native Markdown blocks with inline Foundation formatting. No remote image loading.
private struct NoteMarkdownBody: View {
  let text: String
  private struct Block: Identifiable {
    enum Kind {
      case paragraph
      case heading(Int)
      case quote
      case bullet(String)
      case code, rule
    }
    let id: Int
    let kind: Kind
    let text: String
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(blocks) { block in
        switch block.kind {
        case .paragraph: prose(block.text)
        case .heading(let level):
          prose(block.text).font(
            NotebookTheme.reading(level == 1 ? 26 : level == 2 ? 23 : 20, text: block.text)
          )
          .fontWeight(.semibold).padding(.top, 6).accessibilityAddTraits(.isHeader)
        case .quote:
          prose(block.text).foregroundStyle(NotebookTheme.muted).padding(.leading, 16)
            .overlay(alignment: .leading) {
              Rectangle().fill(NotebookTheme.accent.opacity(0.45)).frame(width: 2)
            }
        case .bullet(let marker):
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(marker).foregroundStyle(NotebookTheme.muted).frame(
              minWidth: 18, alignment: .leading)
            prose(block.text)
          }
        case .code:
          ScrollView(.horizontal) {
            Text(block.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
              .padding(14).frame(maxWidth: .infinity, alignment: .leading)
          }.background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 10))
        case .rule: Rectangle().fill(NotebookTheme.line).frame(height: 1).padding(.vertical, 8)
        }
      }
    }
    .font(NotebookTheme.reading(18, text: text)).foregroundStyle(NotebookTheme.ink)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
  private func prose(_ value: String) -> some View {
    let attributed = try? AttributedString(
      markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    return Text(attributed ?? AttributedString(value)).lineSpacing(6).textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
  private var blocks: [Block] {
    var result: [Block] = []
    var paragraph: [String] = []
    var code: [String]? = nil
    func append(_ kind: Block.Kind, _ content: String) {
      result.append(Block(id: result.count, kind: kind, text: content))
    }
    func flush() {
      if !paragraph.isEmpty {
        append(.paragraph, paragraph.joined(separator: "\n"))
        paragraph = []
      }
    }
    for line in text.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        flush()
        if let lines = code {
          append(.code, lines.joined(separator: "\n"))
          code = nil
        } else {
          code = []
        }
      } else if code != nil {
        code?.append(line)
      } else if trimmed.isEmpty {
        flush()
      } else if ["---", "***", "___"].contains(trimmed) {
        flush()
        append(.rule, "")
      } else if trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "),
        trimmed[..<space].allSatisfy({ $0 == "#" }),
        trimmed.distance(from: trimmed.startIndex, to: space) <= 6
      {
        flush()
        append(
          .heading(trimmed.distance(from: trimmed.startIndex, to: space)),
          String(trimmed[trimmed.index(after: space)...]))
      } else if trimmed.hasPrefix("> ") {
        flush()
        append(.quote, String(trimmed.dropFirst(2)))
      } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ")
        || trimmed.hasPrefix("- [X] ")
      {
        flush()
        append(.bullet(trimmed.hasPrefix("- [ ]") ? "☐" : "☑"), String(trimmed.dropFirst(6)))
      } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
        flush()
        append(.bullet("•"), String(trimmed.dropFirst(2)))
      } else if let dot = trimmed.firstIndex(of: "."), !trimmed[..<dot].isEmpty,
        trimmed[..<dot].allSatisfy({ $0.isNumber }),
        trimmed[trimmed.index(after: dot)...].hasPrefix(" ")
      {
        flush()
        append(
          .bullet(String(trimmed[...dot])),
          String(trimmed[trimmed.index(after: dot)...].dropFirst()))
      } else {
        paragraph.append(line)
      }
    }
    flush()
    if let code { append(.code, code.joined(separator: "\n")) }
    return result
  }
}
