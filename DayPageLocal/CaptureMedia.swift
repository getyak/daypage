import AVFoundation
import CoreTransferable
import DayPageCore
import ImageIO
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PendingNoteAsset: Identifiable, Codable, Sendable {
  var id: UUID
  var data: Data
  var name: String
  var fileExtension: String
  var kind: String
  var duration: Double?

  init(
    id: UUID = UUID(), data: Data, name: String, fileExtension: String, kind: String,
    duration: Double? = nil
  ) {
    self.id = id
    self.data = data
    self.name = name
    self.fileExtension = fileExtension
    self.kind = kind
    self.duration = duration
  }
}

enum CaptureFileReader {
  static let maximumBytes = 25 * 1_024 * 1_024

  static func read(_ url: URL) throws -> Data {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw CaptureError.unreadableFile }
    guard (values.fileSize ?? 0) <= maximumBytes else { throw CaptureError.tooLarge }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var data = Data()
    while let chunk = try file.read(upToCount: min(1_024 * 1_024, maximumBytes + 1 - data.count)),
      !chunk.isEmpty
    {
      data.append(chunk)
      guard data.count <= maximumBytes else { throw CaptureError.tooLarge }
    }
    guard !data.isEmpty else { throw CaptureError.unreadableFile }
    return data
  }

  static func coordinatedRead(_ url: URL) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      var coordinationError: NSError?
      var result: Result<Data, Error>?
      NSFileCoordinator().coordinate(
        readingItemAt: url, options: .withoutChanges, error: &coordinationError
      ) { readableURL in
        result = Result { try read(readableURL) }
      }
      if let coordinationError { throw coordinationError }
      guard let result else { throw CaptureError.unreadableFile }
      return try result.get()
    }.value
  }
}

enum CaptureError: LocalizedError {
  case tooLarge, unreadableFile, unavailableCamera, recordingFailed, anotherRecording
  var errorDescription: String? {
    switch self {
    case .tooLarge: return String(localized: "Choose an attachment smaller than 25 MB.")
    case .unreadableFile:
      return String(localized: "This file could not be opened. Download it in Files and try again.")
    case .unavailableCamera:
      return String(localized: "The camera is unavailable on this device. Choose a photo instead.")
    case .recordingFailed:
      return String(localized: "Recording could not continue. Your note draft is still here.")
    case .anotherRecording:
      return String(
        localized: "Another recording is in progress. Finish it before starting a new one.")
    }
  }
}

/// Bounded file loading stays within the photo provider's temporary-file lifetime.
struct PickedNotePhoto: Transferable {
  let data: Data
  let filename: String
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      let data = try await Task.detached(priority: .userInitiated) {
        try CaptureFileReader.read(received.file)
      }.value
      let source = CGImageSourceCreateWithData(data as CFData, nil)
      guard let source, let identifier = CGImageSourceGetType(source),
        let fileExtension = UTType(identifier as String)?.preferredFilenameExtension
      else { throw CaptureError.unreadableFile }
      let stem = received.file.deletingPathExtension().lastPathComponent
      return PickedNotePhoto(data: data, filename: stem + "." + fileExtension)
    }
  }
}

struct LocalPhotoThumbnail: View {
  var url: URL? = nil
  var data: Data? = nil
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      NotebookTheme.card
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: "photo").foregroundStyle(NotebookTheme.muted)
      }
    }
    .clipped()
    .task(id: url?.absoluteString ?? String(data?.count ?? 0)) {
      let url = url
      let data = data
      let loaded = await Task.detached(priority: .utility) {
        let source: CGImageSource?
        if let url, url.isFileURL {
          source = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else if let data {
          source = CGImageSourceCreateWithData(data as CFData, nil)
        } else {
          source = nil
        }
        guard let source,
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 420,
              kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        else { return UIImage?.none }
        return UIImage(cgImage: thumbnail)
      }.value
      guard !Task.isCancelled else { return }
      image = loaded
    }
  }
}

struct NoteAttachmentStrip: View {
  let entry: NotebookEntry
  @State private var preview: URL?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        ForEach(Array(entry.memo.attachments.enumerated()), id: \.offset) { _, attachment in
          StoredAttachmentTile(entry: entry, attachment: attachment) { preview = $0 }
        }
      }.padding(.vertical, 3)
    }
    .quickLookPreview($preview)
  }
}

private struct StoredAttachmentTile: View {
  @EnvironmentObject private var notebook: NotebookModel
  let entry: NotebookEntry
  let attachment: Memo.Attachment
  let onPreview: (URL) -> Void
  @State private var url: URL?
  @State private var loading = false

  private var filename: String { URL(fileURLWithPath: attachment.file).lastPathComponent }
  var body: some View {
    Button {
      guard !loading else { return }
      loading = true
      Task {
        defer { loading = false }
        do { onPreview(try await notebook.store.assetURL(attachment.file, for: entry)) } catch {
          notebook.report(error)
        }
      }
    } label: {
      Group {
        if attachment.kind == "photo" {
          LocalPhotoThumbnail(url: url).frame(width: 96, height: 96)
        } else {
          HStack(spacing: 10) {
            Image(systemName: attachment.kind == "audio" ? "play.circle.fill" : "doc")
              .font(.title2).foregroundStyle(NotebookTheme.accent)
            VStack(alignment: .leading, spacing: 5) {
              Text(attachment.kind == "audio" ? String(localized: "Voice note") : filename)
                .font(.subheadline).lineLimit(2)
              if let duration = attachment.duration {
                Text(captureDuration(duration)).font(NotebookTheme.mono(11)).foregroundStyle(
                  NotebookTheme.muted)
              } else {
                Text(URL(fileURLWithPath: filename).pathExtension.uppercased())
                  .font(.caption2).foregroundStyle(NotebookTheme.muted)
              }
            }
            if loading { ProgressView() }
          }
          .padding(14).frame(width: 190, height: 96, alignment: .leading).background(
            NotebookTheme.card)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NotebookTheme.line))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(attachment.kind == "audio" ? "Play voice note" : "Open attachment"))
    .accessibilityValue(filename)
    .task(id: entry.id + attachment.file) {
      do { url = try await notebook.store.assetURL(attachment.file, for: entry) } catch
      { /* A tap reports failure without interrupting the timeline. */  }
    }
  }
}

struct PendingAttachmentStrip: View {
  let assets: [PendingNoteAsset]
  let disabled: Bool
  let onRemove: (UUID) -> Void
  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        ForEach(assets) { asset in
          VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
              if asset.kind == "photo" {
                LocalPhotoThumbnail(data: asset.data).frame(width: 100, height: 80)
                  .clipShape(RoundedRectangle(cornerRadius: 10))
              } else {
                Label(
                  asset.kind == "audio" ? "Voice note" : "File",
                  systemImage: asset.kind == "audio" ? "waveform" : "doc"
                )
                .font(.caption).foregroundStyle(NotebookTheme.ink)
                .frame(width: 120, height: 80).background(NotebookTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
              }
              Button {
                onRemove(asset.id)
              } label: {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                  .foregroundStyle(.white, Color.black.opacity(0.7))
                  .font(.system(size: 20)).frame(width: 44, height: 44)
              }
              .buttonStyle(.plain).disabled(disabled).accessibilityLabel("Remove attachment")
            }
            Text(asset.duration.map(captureDuration) ?? asset.name)
              .font(.caption2).foregroundStyle(NotebookTheme.muted).lineLimit(1)
              .frame(width: asset.kind == "photo" ? 100 : 120, alignment: .leading)
          }
        }
      }.padding(.vertical, 3)
    }
  }
}

func captureDuration(_ seconds: Double) -> String {
  let seconds = Int(max(0, min(seconds.isFinite ? seconds : 0, 31_536_000)))
  return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

struct NoteCameraPicker: UIViewControllerRepresentable {
  let onCapture: (UIImage) -> Void
  @Environment(\.dismiss) private var dismiss
  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
  func makeUIViewController(context: Context) -> UIImagePickerController {
    let controller = UIImagePickerController()
    controller.sourceType = .camera
    controller.mediaTypes = [UTType.image.identifier]
    controller.delegate = context.coordinator
    return controller
  }
  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
  final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate
  {
    let parent: NoteCameraPicker
    init(parent: NoteCameraPicker) { self.parent = parent }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
      parent.dismiss()
    }
  }
}

struct NoteShareSheet: UIViewControllerRepresentable {
  let items: [Any]
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor
func noteShareItems(entry: NotebookEntry, store: NotebookStore) async throws -> [Any] {
  var items: [Any] = entry.memo.body.isEmpty ? [] : [entry.memo.body]
  for attachment in entry.memo.attachments {
    items.append(try await store.assetURL(attachment.file, for: entry))
  }
  return items
}

@MainActor
private final class LocalVoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
  enum Phase { case ready, requesting, recording, paused, stopped }
  @Published private(set) var phase = Phase.ready
  @Published private(set) var duration: Double = 0
  @Published private(set) var error: String?
  @Published private(set) var permissionDenied = false
  private static weak var owner: LocalVoiceRecorder?
  private let limit: Double = 600
  private var recorder: AVAudioRecorder?
  private var file: URL?
  private var timer: Timer?
  private var ownsSession = false
  private var cancelled = false
  var hasRecording: Bool { duration > 0 && file != nil }
  var needsDiscard: Bool { file != nil }

  func start() async {
    guard phase == .ready else { return }
    guard Self.owner == nil || Self.owner === self else {
      error = CaptureError.anotherRecording.localizedDescription
      return
    }
    Self.owner = self
    cancelled = false
    error = nil
    phase = .requesting
    let session = AVAudioSession.sharedInstance()
    let allowed = await withCheckedContinuation { continuation in
      session.requestRecordPermission { continuation.resume(returning: $0) }
    }
    guard !cancelled else { return }
    guard allowed else {
      permissionDenied = true
      phase = .ready
      releaseSession()
      return
    }
    permissionDenied = false
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
      try session.setActive(true)
      ownsSession = true
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "daypage-voice-\(UUID().uuidString).m4a")
      file = url
      let recorder = try AVAudioRecorder(
        url: url,
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
          AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
          AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
      recorder.delegate = self
      self.recorder = recorder
      guard recorder.record(forDuration: limit) else { throw CaptureError.recordingFailed }
      phase = .recording
      beginTimer()
    } catch {
      self.error = error.localizedDescription
      phase = .ready
      cleanup()
    }
  }
  func pause() {
    guard phase == .recording, let recorder else { return }
    duration = recorder.currentTime
    recorder.pause()
    phase = .paused
    stopTimer()
    deactivateSession()
  }
  func resume() {
    guard phase == .paused, let recorder, duration < limit else { return }
    do {
      try AVAudioSession.sharedInstance().setActive(true)
      ownsSession = true
      guard recorder.record(forDuration: max(0, limit - duration)) else {
        throw CaptureError.recordingFailed
      }
      error = nil
      phase = .recording
      beginTimer()
    } catch { self.error = error.localizedDescription }
  }
  func finish() async -> (Data, Double)? {
    guard hasRecording, let file else { return nil }
    if phase == .recording { duration = recorder?.currentTime ?? duration }
    recorder?.delegate = nil
    recorder?.stop()
    recorder = nil
    stopTimer()
    phase = .stopped
    releaseSession()
    do {
      let data = try await Task.detached(priority: .userInitiated) {
        try CaptureFileReader.read(file)
      }.value
      guard !cancelled else { return nil }
      // Keep the only recording file until the caller confirms its durable
      // draft write. A quota/disk failure must leave this result retryable.
      return (data, duration)
    } catch {
      self.error = error.localizedDescription
      return nil
    }
  }
  func cancel() {
    cancelled = true
    cleanup()
  }
  func enteredBackground() {
    if phase == .requesting {
      cancelled = true
      phase = .ready
      releaseSession()
    } else {
      pause()
    }
  }
  func refreshPermission() {
    if AVAudioSession.sharedInstance().recordPermission == .granted { permissionDenied = false }
  }
  private func beginTimer() {
    stopTimer()
    timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.phase == .recording else { return }
        self.duration = min(self.limit, self.recorder?.currentTime ?? self.duration)
      }
    }
  }
  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }
  private func releaseSession() {
    deactivateSession()
    if Self.owner === self { Self.owner = nil }
  }
  private func deactivateSession() {
    if ownsSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      ownsSession = false
    }
  }
  private func cleanup() {
    stopTimer()
    recorder?.delegate = nil
    recorder?.stop()
    recorder = nil
    if let file { try? FileManager.default.removeItem(at: file) }
    file = nil
    releaseSession()
  }
  nonisolated func audioRecorderDidFinishRecording(
    _ recorder: AVAudioRecorder, successfully flag: Bool
  ) {
    Task { @MainActor [weak self] in
      guard let self, self.recorder === recorder else { return }
      self.duration = min(self.limit, max(self.duration, recorder.currentTime))
      self.phase = .stopped
      self.stopTimer()
      self.releaseSession()
      if !flag { self.error = CaptureError.recordingFailed.localizedDescription }
    }
  }
  nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    Task { @MainActor [weak self] in
      guard let self, self.recorder === recorder else { return }
      self.pause()
      self.error = CaptureError.recordingFailed.localizedDescription
    }
  }
}

struct VoiceCaptureView: View {
  let onComplete: (Data, Double) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var recorder = LocalVoiceRecorder()
  @State private var finishing = false
  @State private var confirmingDiscard = false
  @State private var isVisible = false
  @State private var transferFailed = false
  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Spacer(minLength: 12)
        Image(systemName: recorder.phase == .recording ? "waveform" : "mic")
          .font(.system(size: 38, weight: .light)).foregroundStyle(NotebookTheme.accent)
          .accessibilityHidden(true)
        Text(captureDuration(recorder.duration))
          .font(.system(size: 42, weight: .light, design: .monospaced)).monospacedDigit()
          .accessibilityLabel("Recording duration")
        Text(status).font(.subheadline).foregroundStyle(NotebookTheme.muted).multilineTextAlignment(
          .center)
        if recorder.permissionDenied {
          VStack(spacing: 12) {
            Text("Allow microphone access in Settings to record a voice note.")
              .font(.subheadline).multilineTextAlignment(.center)
            Button("Open Settings") { openAppSettings() }.buttonStyle(.bordered)
          }
        }
        if let error = recorder.error {
          Text(error).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center)
        }
        if transferFailed {
          Text("This recording is still here. Free some draft space or try adding it again.")
            .font(.subheadline).foregroundStyle(NotebookTheme.muted).multilineTextAlignment(.center)
            .accessibilityIdentifier("recording-kept")
        }
        controls
        Text("Audio stays in your notebook. Recording pauses when you leave the app.")
          .font(.caption).foregroundStyle(NotebookTheme.muted).multilineTextAlignment(.center)
        Spacer(minLength: 12)
      }
      .padding(24).frame(maxWidth: .infinity).notebookSurface()
      .navigationTitle("Voice note").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            if recorder.needsDiscard {
              confirmingDiscard = true
            } else {
              recorder.cancel()
              dismiss()
            }
          }.disabled(finishing)
        }
      }
    }
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    .interactiveDismissDisabled(recorder.needsDiscard || recorder.phase == .requesting || finishing)
    .confirmationDialog(
      "Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible
    ) {
      Button("Discard recording", role: .destructive) {
        recorder.cancel()
        dismiss()
      }
      Button("Keep recording", role: .cancel) {}
    }
    .onChange(of: scenePhase) { phase in
      if phase == .background {
        recorder.enteredBackground()
      } else if phase == .inactive {
        recorder.pause()
      } else {
        recorder.refreshPermission()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) {
      _ in recorder.pause()
    }
    .onAppear { isVisible = true }
    .onDisappear {
      isVisible = false
      recorder.cancel()
    }
  }
  private var status: LocalizedStringKey {
    switch recorder.phase {
    case .ready: return "Ready when you are"
    case .requesting: return "Waiting for microphone access"
    case .recording: return "Recording · up to 10 minutes"
    case .paused: return "Paused · resume or add to your note"
    case .stopped: return "Recording stopped · add it to your note"
    }
  }
  private var controls: some View {
    HStack(spacing: 16) {
      if recorder.phase == .ready || recorder.phase == .requesting {
        Button {
          Task { await recorder.start() }
        } label: {
          Label("Start recording", systemImage: "record.circle").frame(minHeight: 44).padding(
            .horizontal, 8)
        }
        .buttonStyle(.borderedProminent).tint(NotebookTheme.accent)
        .disabled(recorder.phase == .requesting || recorder.permissionDenied)
        .accessibilityIdentifier("start-recording")
      } else {
        if recorder.phase != .stopped {
          Button {
            if recorder.phase == .recording { recorder.pause() } else { recorder.resume() }
          } label: {
            Label(
              recorder.phase == .recording ? "Pause" : "Resume",
              systemImage: recorder.phase == .recording ? "pause" : "play"
            )
            .frame(minHeight: 44)
          }.buttonStyle(.bordered).disabled(finishing).accessibilityIdentifier("pause-recording")
        }
        Button {
          finishing = true
          Task {
            if let (data, duration) = await recorder.finish(), isVisible {
              let accepted = await onComplete(data, duration)
              guard isVisible else { finishing = false; return }
              if accepted {
                recorder.cancel()
                dismiss()
              } else {
                transferFailed = true
              }
            }
            finishing = false
          }
        } label: {
          if finishing {
            ProgressView().frame(minHeight: 44)
          } else {
            Label("Add recording", systemImage: "checkmark").frame(minHeight: 44)
          }
        }
        .buttonStyle(.borderedProminent).tint(NotebookTheme.accent)
        .disabled(finishing || !recorder.hasRecording).accessibilityIdentifier("finish-recording")
      }
    }
  }
}

func openAppSettings() {
  guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
  UIApplication.shared.open(url)
}
