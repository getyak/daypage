import DayPageCapture
import DayPageCore
import ImageIO
import SwiftUI
import UIKit

@MainActor
private final class ScreenshotReviewModel: ObservableObject {
  @Published var captures: [ScreenshotCapture] = []
  @Published var recoveries: [ScreenshotRecovery] = []
  @Published var selected: ScreenshotCapture?
  @Published var showRecovery = false
  @Published var error: String?
  @Published var busy = false
  private var refreshing = false
  private var refreshRequested = false
  private var openRequested = false
  private var readIssue: String?

  func refresh(open: Bool = false) async {
    openRequested = openRequested || open
    refreshRequested = true
    guard !refreshing, !busy else { return }
    refreshing = true
    defer { refreshing = false }
    repeat {
      refreshRequested = false
      do {
        let inbox = try ScreenshotInboxLocation.make()
        recoveries = try await inbox.recoveries()
        captures = try await inbox.captures()
        readIssue = nil
      } catch {
        readIssue = Self.message(error)
        if !captures.isEmpty || !recoveries.isEmpty { self.error = readIssue }
      }
    } while refreshRequested && !busy
    if openRequested && !busy {
      openRequested = false
      if let first = captures.first { selected = first }
      else if !recoveries.isEmpty { showRecovery = true }
      else { error = readIssue ?? String(localized: "No pending shared images.") }
    }
  }

  func recover(_ item: ScreenshotRecovery) async {
    guard !busy else { return }
    busy = true
    do { _ = try await ScreenshotInboxLocation.make().recover(item); error = nil }
    catch { self.error = Self.message(error) }
    busy = false
    await refresh()
  }

  func discardRecovery(_ item: ScreenshotRecovery) async {
    guard !busy else { return }
    busy = true
    do { try await ScreenshotInboxLocation.make().discardRecovery(item); error = nil }
    catch { self.error = Self.message(error) }
    busy = false
    await refresh()
  }

  func discard(_ capture: ScreenshotCapture) async {
    guard !busy else { return }
    busy = true
    do {
      try await ScreenshotInboxLocation.make().remove(capture)
      selected = nil
    } catch { self.error = Self.message(error) }
    busy = false
    await refresh()
  }

  func save(_ capture: ScreenshotCapture, caption: String, notebook: NotebookModel) async {
    guard !busy, !notebook.isLoading else { return }
    busy = true
    do {
      let inbox = try ScreenshotInboxLocation.make()
      let result = try await ScreenshotNoteSaver.save(capture, caption: caption, inbox: inbox, store: notebook.store)
      await notebook.refresh()
      notebook.revealIncomingCapture(capture.id)
      selected = nil
      if !result.inboxAcknowledged {
        error = String(localized: "Your note was saved. Review the pending image again to finish local cleanup.")
      }
    } catch { self.error = Self.message(error) }
    busy = false
    await refresh()
  }

  static func message(_ error: Error) -> String {
    if let error = error as? ScreenshotInboxError { return error.localizedDescription }
    return String(localized: "This image could not be saved. Its original is still available to retry.")
  }
}

/// Pending captures never replace the ordinary editor or its draft. The person
/// opens this separate review before any Vault publication.
struct ScreenshotInboxView<Content: View>: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.scenePhase) private var phase
  @StateObject private var review = ScreenshotReviewModel()
  #if DEBUG
    @State private var seededSyntheticInbox = false
  #endif
  let content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    VStack(spacing: 0) {
      if !review.captures.isEmpty {
        Button { review.selected = review.captures.first } label: {
          HStack {
            Label("Review shared images", systemImage: "photo.on.rectangle")
            Spacer()
            Text("\(review.captures.count)").monospacedDigit()
          }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(NotebookTheme.paper)
        .accessibilityIdentifier("review-shared-images")
      }
      if !review.recoveries.isEmpty {
        Button { review.showRecovery = true } label: {
          HStack {
            Label("Manage interrupted images", systemImage: "exclamationmark.triangle")
            Spacer()
            Text("\(review.recoveries.count)").monospacedDigit()
          }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(NotebookTheme.paper)
        .accessibilityIdentifier("manage-interrupted-images")
      }
      content
    }
    .task {
      #if DEBUG
        if !seededSyntheticInbox {
          seededSyntheticInbox = true
          do { try await ScreenshotInboxLocation.seedSyntheticUIInboxIfRequested() }
          catch { review.error = ScreenshotReviewModel.message(error) }
        }
      #endif
      await review.refresh()
    }
    .onChange(of: phase) { if $0 == .active { Task { await review.refresh() } } }
    .onReceive(NotificationCenter.default.publisher(for: ScreenshotInboxLocation.changed)) { _ in
      Task { await review.refresh() }
    }
    .onReceive(NotificationCenter.default.publisher(for: ScreenshotInboxLocation.reviewRequested)) { _ in
      Task { await review.refresh(open: true) }
    }
    .sheet(item: $review.selected) { capture in
      ScreenshotReviewView(capture: capture, review: review)
        .id(capture.id)
        .environmentObject(notebook)
    }
    .sheet(isPresented: $review.showRecovery) { ScreenshotRecoveryView(review: review) }
    .alert("Shared image needs attention", isPresented: Binding(
      get: { review.error != nil }, set: { if !$0 { review.error = nil } })) {
      Button("OK", role: .cancel) { review.error = nil }
    } message: { Text(review.error ?? "") }
  }
}

@MainActor
private struct ScreenshotRecoveryView: View {
  @ObservedObject var review: ScreenshotReviewModel
  @Environment(\.dismiss) private var dismiss
  @State private var discarding: ScreenshotRecovery?

  var body: some View {
    NavigationStack {
      List {
        Text("Interrupted images stay here until you recover or discard them. Recovery does not save a note.")
          .font(.footnote)
        if let error = review.error { Text(error).foregroundStyle(.secondary) }
        if review.recoveries.isEmpty { Text("No interrupted images remain. Close this screen to review recovered images.") }
        ForEach(review.recoveries) { item in
          VStack(alignment: .leading, spacing: 12) {
            Text("Interrupted image").font(.headline)
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))
              .font(.caption).foregroundStyle(.secondary)
            Button("Recover image") { Task { await review.recover(item) } }.disabled(review.busy)
            Button("Discard interrupted image", role: .destructive) { discarding = item }.disabled(review.busy)
          }.padding(.vertical, 8)
        }
      }
      .navigationTitle("Interrupted images").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(review.busy) } }
      .interactiveDismissDisabled(review.busy)
      .confirmationDialog("Discard the interrupted original and its recovery files?", isPresented: Binding(
        get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible,
        presenting: discarding) { item in
          Button("Discard interrupted image", role: .destructive) { Task { await review.discardRecovery(item) } }
          Button("Cancel", role: .cancel) { }
        }
    }
  }
}

@MainActor
private struct ScreenshotReviewView: View {
  let capture: ScreenshotCapture
  @ObservedObject var review: ScreenshotReviewModel
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dismiss) private var dismiss
  @State private var caption = ""
  @State private var thumbnail: UIImage?
  @State private var loadError: String?
  @State private var confirmDiscard = false
  @State private var extracting = false
  @State private var extractedText: String?
  @State private var extractionIssue: String?
  @State private var extractedAdded = false
  @State private var extractionEpoch = UUID()
  @State private var extractionTask: Task<Void, Never>?
  #if DEBUG
    @StateObject private var extractionDiagnostics = SyntheticOCRDiagnostics()
  #endif

  private var syntheticOCRPhase: String? {
    #if DEBUG
      return ScreenshotInboxLocation.recordsSyntheticOCRDiagnostics ? extractionDiagnostics.phase : nil
    #else
      return nil
    #endif
  }

  private var syntheticOCRWorkerFactsValue: (() -> String?)? {
    #if DEBUG
      guard ScreenshotInboxLocation.recordsSyntheticOCRDiagnostics,
        extractionDiagnostics.workerFacts != nil else { return nil }
      return { extractionDiagnostics.workerFactsValue() }
    #else
      return nil
    #endif
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if let error = review.error { Text(error).foregroundStyle(.secondary) }
          if let thumbnail {
            Image(uiImage: thumbnail).resizable().scaledToFit()
              .accessibilityLabel("Shared image preview")
          } else if let loadError { Text(loadError) }
          else { ProgressView("Loading image…") }
        }
        Section("Note") { TextEditor(text: $caption).frame(minHeight: 90)
          .accessibilityIdentifier("shared-image-caption") }
        Section("On-device text") {
          if extracting {
            ProgressView("Extracting text on this device…")
              .modifier(SyntheticOCRDiagnosticValue(
                phase: syntheticOCRPhase, pendingIdentifier: "qa-shared-image-ocr-phase",
                workerFactsValue: syntheticOCRWorkerFactsValue))
            Button("Cancel extraction") { cancelExtraction() }
          } else {
            Button("Extract text on this device") { extractText() }
              .disabled(thumbnail == nil || review.busy)
              .accessibilityIdentifier("extract-shared-image-text")
              .modifier(SyntheticOCRDiagnosticValue(phase: syntheticOCRPhase,
                workerFactsValue: syntheticOCRWorkerFactsValue))
          }
          if let extractedText {
            Text(extractedText).textSelection(.enabled)
              .accessibilityIdentifier("shared-image-extracted-text")
            Button("Add to note text") {
              let proposed = caption.isEmpty ? extractedText : caption + "\n\n" + extractedText
              guard proposed.utf8.count <= 4 * 1024 * 1024 else {
                extractionIssue = String(localized: "The note text is too long. Your text has not changed.")
                return
              }
              caption = proposed
              extractedAdded = true
            }.disabled(extractedAdded || review.busy)
              .accessibilityIdentifier("add-shared-image-text")
          }
          if let extractionIssue { Text(extractionIssue).foregroundStyle(.secondary) }
          Text("Text recognition runs only on this device. Review it before adding it to your note.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
          Text("Nothing is saved to your notebook until you choose Save note. No image is sent to AI.")
            .font(.footnote).foregroundStyle(.secondary)
          Button("Save note") { Task { await review.save(capture, caption: caption, notebook: notebook) } }
            .disabled(thumbnail == nil || review.busy || notebook.isLoading)
            .accessibilityIdentifier("save-shared-image")
          Button("Discard image", role: .destructive) { confirmDiscard = true }.disabled(review.busy)
        }
      }
      .navigationTitle("Review shared image").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) {
        Button("Later") { dismiss() }.disabled(review.busy)
      } }
      .confirmationDialog("Discard this pending image?", isPresented: $confirmDiscard, titleVisibility: .visible) {
        Button("Discard image", role: .destructive) { Task { await review.discard(capture) } }
          .accessibilityIdentifier("confirm-discard-shared-image")
        Button("Cancel", role: .cancel) { }
      }
      .interactiveDismissDisabled(review.busy)
      .onDisappear { cancelExtraction() }
      .task(id: capture.id) {
        do {
          let data = try await ScreenshotInboxLocation.make().image(capture)
          let image = try await Task.detached(priority: .userInitiated) { () -> CGImage in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                 kCGImageSourceCreateThumbnailWithTransform as String: true,
                 kCGImageSourceThumbnailMaxPixelSize as String: 1024] as CFDictionary) else {
              throw ScreenshotInboxError.invalidImage
            }
            return image
          }.value
          thumbnail = UIImage(cgImage: image)
        } catch { loadError = ScreenshotReviewModel.message(error) }
      }
    }
  }

  private func extractText() {
    guard !extracting, !review.busy else { return }
    cancelExtraction()
    let epoch = UUID()
    extractionEpoch = epoch
    extracting = true
    extractedText = nil
    extractionIssue = nil
    extractedAdded = false
    #if DEBUG
      let diagnostics = ScreenshotInboxLocation.recordsSyntheticOCRDiagnostics ? extractionDiagnostics : nil
      diagnostics?.begin(epoch)
      let workerFacts = diagnostics?.workerFacts
    #endif
    extractionTask = Task {
      do {
        let inbox = try ScreenshotInboxLocation.make()
        #if DEBUG
          // Diagnostic callbacks can reach only the same dedicated synthetic
          // root whose pixels were generated by the QA seeding owner.
          let diagnosticRoot = await inbox.root
          let scopedDiagnostics = diagnosticRoot.lastPathComponent == "ScreenshotInbox-UI-GET440" ? diagnostics : nil
        #endif
        let data = try await inbox.image(capture)
        #if DEBUG
          scopedDiagnostics?.record("original_loaded", epoch: epoch)
          let text: String
          if let scopedDiagnostics {
            text = try await AttachmentTextReader.readImage(data: data, diagnostic: { phase in
              Task { @MainActor in scopedDiagnostics.record(phase, epoch: epoch) }
            }, workerFacts: workerFacts)
          } else { text = try await AttachmentTextReader.readImage(data: data) }
        #else
          let text = try await AttachmentTextReader.readImage(data: data)
        #endif
        guard !Task.isCancelled, extractionEpoch == epoch else { return }
        extractedText = text
        #if DEBUG
          diagnostics?.record("completed", epoch: epoch)
        #endif
      } catch is CancellationError {
        guard extractionEpoch == epoch else { return }
        #if DEBUG
          diagnostics?.record("cancelled", epoch: epoch)
        #endif
      } catch {
        guard !Task.isCancelled, extractionEpoch == epoch else { return }
        extractionIssue = String(localized: "No readable text was returned. You can still save the original image.")
        #if DEBUG
          diagnostics?.record("failed", epoch: epoch)
        #endif
      }
      guard extractionEpoch == epoch else { return }
      extracting = false
      extractionTask = nil
    }
  }

  private func cancelExtraction() {
    #if DEBUG
      extractionDiagnostics.cancel()
    #endif
    extractionEpoch = UUID()
    extractionTask?.cancel()
    extractionTask = nil
    extracting = false
  }
}

/// No ordinary/Release accessibility value is changed. Synthetic diagnostics
/// are static phase names, not user content or a substitute OCR result.
private struct SyntheticOCRDiagnosticValue: ViewModifier {
  let phase: String?
  var pendingIdentifier: String? = nil
  var workerFactsValue: (() -> String?)? = nil
  @ViewBuilder private var workerMetadata: some View {
    #if DEBUG
      if let workerFactsValue {
        SyntheticOCRFactsAccessibility(read: workerFactsValue)
          .frame(width: 1, height: 1).allowsHitTesting(false)
      }
    #endif
  }
  @ViewBuilder func body(content: Content) -> some View {
    if let phase {
      if let pendingIdentifier {
        content.accessibilityValue("GET440 OCR phase: " + phase)
          .accessibilityIdentifier(pendingIdentifier)
          .background { workerMetadata }
      } else {
        content.accessibilityValue("GET440 OCR phase: " + phase)
          .background { workerMetadata }
      }
    } else { content }
  }
}

#if DEBUG
/// The existing phase label remains unchanged. This synthetic-only node reads
/// the worker lock on each AX value request, even without a SwiftUI re-render.
@MainActor
private struct SyntheticOCRFactsAccessibility: UIViewRepresentable {
  let read: () -> String?
  func makeUIView(context: Context) -> SyntheticOCRFactsAccessibilityView {
    let view = SyntheticOCRFactsAccessibilityView()
    view.isAccessibilityElement = true
    view.accessibilityIdentifier = "qa-shared-image-ocr-worker-facts"
    view.accessibilityTraits = .staticText
    view.isUserInteractionEnabled = false
    view.backgroundColor = .clear
    view.read = read
    return view
  }
  func updateUIView(_ view: SyntheticOCRFactsAccessibilityView, context: Context) { view.read = read }
}

@MainActor
private final class SyntheticOCRFactsAccessibilityView: UIView {
  var read: (() -> String?)?
  override var accessibilityValue: String? {
    get { read?() }
    set {} // Read-only metadata; no AX setter writes product or worker state.
  }
}

@MainActor
private final class SyntheticOCRDiagnostics: ObservableObject {
  @Published private(set) var phase = "not_started"
  private var epoch: UUID?
  private(set) var workerFacts: SyntheticOCRWorkerFacts?
  private var rank = 0
  private let ranks = ["original_read": 1, "original_loaded": 2, "worker_entered": 3,
    "decode_started": 4, "vision_entered": 5, "vision_returned": 6,
    "vision_failed": 7, "completed": 8, "failed": 9, "cancelled": 10]

  func begin(_ epoch: UUID) {
    self.epoch = epoch
    workerFacts = SyntheticOCRWorkerFacts()
    rank = 0
    record("original_read", epoch: epoch)
  }

  /// Called by the AX getter, not a SwiftUI body snapshot. Only relative,
  /// bounded worker facts and the separate last UI publication leave the model.
  func workerFactsValue() -> String? {
    guard let facts = workerFacts?.snapshot() else { return nil }
    func number(_ value: Int?) -> String { value.map { String($0) } ?? "null" }
    return "GET440 OCR worker facts: "
      + "{\"v\":1,\"ui\":\"\(phase)\",\"admittedMS\":0,"
      + "\"workerEnteredMS\":\(number(facts.workerEnteredMS)),\"decodeStartedMS\":\(number(facts.decodeStartedMS)),"
      + "\"visionEnteredMS\":\(number(facts.visionEnteredMS)),\"visionReturnedMS\":\(number(facts.visionReturnedMS)),"
      + "\"visionFailedMS\":\(number(facts.visionFailedMS)),\"sampledMS\":\(number(facts.sampledMS)),"
      + "\"clamped\":\(facts.clamped),\"clockValid\":\(facts.clockValid)}"
  }

  func record(_ phase: String, epoch: UUID) {
    guard self.epoch == epoch, let next = ranks[phase], next >= rank else { return }
    rank = next
    self.phase = phase
  }

  func cancel() {
    guard let epoch else { return }
    record("cancelled", epoch: epoch)
    self.epoch = nil
  }
}
#endif
