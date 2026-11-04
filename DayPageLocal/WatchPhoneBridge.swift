import AVFoundation
import DayPageCore
import Foundation
import Speech
import UIKit
import WatchConnectivity

private struct WatchInboxEnvelope: Codable {
  let capture: WatchCapture
  let audio: Data
}

@MainActor
final class WatchPhoneBridge: NSObject, ObservableObject, WCSessionDelegate {
  @Published private(set) var status = String(localized: "Watch recordings arrive automatically when the devices reconnect.")
  @Published private(set) var transcribes: Bool
  private let store: NotebookStore
  private let inbox: WatchCaptureStore
  nonisolated private let spool: URL
  private let defaults: UserDefaults
  private let disabled: Bool
  private var draining = false
  private var transcribing = false
  private var recognition: SFSpeechRecognitionTask?
  var didChange: (() async -> Void)?

  init(store: NotebookStore, root: URL, defaults: UserDefaults, disabled: Bool) {
    self.store = store; self.defaults = defaults; self.disabled = disabled
    transcribes = defaults.bool(forKey: "watch.onDeviceTranscription")
    let base = root.deletingLastPathComponent().appendingPathComponent(".daypage-watch-inbox")
    inbox = WatchCaptureStore(root: base.appendingPathComponent("captures"))
    spool = base.appendingPathComponent("received")
    super.init()
  }
  func start() async {
    guard !disabled else { return }
    activateSession()
    await resume()
  }
  func activateSession() {
    guard !disabled, WCSession.isSupported() else { return }
    WCSession.default.delegate = self; WCSession.default.activate()
  }
  func resume() async {
    guard !disabled else { return }
    await drain()
    await transcribePending()
  }
  func setTranscribes(_ value: Bool) async {
    if !value {
      recognition?.cancel(); transcribes = false; defaults.set(false, forKey: "watch.onDeviceTranscription"); return
    }
    let permission = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    transcribes = permission == .authorized
    defaults.set(transcribes, forKey: "watch.onDeviceTranscription")
    if transcribes { await transcribePending() }
    else { status = String(localized: "Speech permission is off. Original Watch audio is still saved.") }
  }
  private func drain() async {
    guard !draining else { return }; draining = true; defer { draining = false }
    do {
      var received = Set<UUID>()
      var hasFailure = false
      let files = (try? FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil)) ?? []
      for file in files where file.pathExtension == "json" {
        do {
          let envelope = try JSONDecoder().decode(WatchInboxEnvelope.self, from: Data(contentsOf: file))
          try await inbox.stage(envelope.capture, audio: envelope.audio)
          received.insert(envelope.capture.id)
          // The canonical inbox now owns the original; receipt creation is independently retryable.
          try FileManager.default.removeItem(at: file)
        } catch { hasFailure = true }
      }
      for capture in try await inbox.captures() {
        do {
          let receipt = try await inbox.importCapture(capture.id, into: store)
          let key = "watch.receiptQueued." + capture.id.uuidString
          if WCSession.default.activationState == .activated,
            !defaults.bool(forKey: key) || received.contains(capture.id) {
            WCSession.default.transferUserInfo(["daypage.receipt.v1": try JSONEncoder().encode(receipt)])
            defaults.set(true, forKey: key)
          }
        } catch { hasFailure = true }
      }
      status = hasFailure ? String(localized: "Some Watch originals need another delivery attempt. Saved notes remain available.")
        : String(localized: "Watch originals are saved in DayPage.")
      await didChange?()
    } catch { status = error.localizedDescription }
  }

  /// WCSession deletes file.fileURL after this callback. Persist the complete envelope before returning.
  nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
    do {
      guard let data = file.metadata?["daypage.capture.v1"] as? Data else { return }
      let capture = try JSONDecoder().decode(WatchCapture.self, from: data)
      try capture.validate()
      let values = try file.fileURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
      guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 25 * 1024 * 1024 else { return }
      let audio = try Data(contentsOf: file.fileURL)
      guard !audio.isEmpty, ReplicaDigest.hash(audio) == capture.digest else { return }
      try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
      let destination = spool.appendingPathComponent(capture.id.uuidString + "-" + capture.digest + ".json")
      try JSONEncoder().encode(WatchInboxEnvelope(capture: capture, audio: audio)).write(to: destination, options: .atomic)
      Task { @MainActor [weak self] in await self?.drain(); await self?.transcribePending() }
    } catch {
      // No receipt: the Watch retains its original and retries. Never log private paths or transcripts.
    }
  }
  nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
    if state == .activated { Task { @MainActor [weak self] in await self?.drain() } }
  }
  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
  nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
  nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
    guard error != nil, let data = userInfoTransfer.userInfo["daypage.receipt.v1"] as? Data,
      let receipt = try? JSONDecoder().decode(WatchCaptureReceipt.self, from: data) else { return }
    Task { @MainActor [weak self] in self?.defaults.set(false, forKey: "watch.receiptQueued." + receipt.id.uuidString) }
  }
  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
    guard let ids = message["daypage.receipt.request.v1"] as? [String], ids.count <= 100 else {
      replyHandler([:]); return
    }
    Task { @MainActor [weak self] in
      guard let self else { replyHandler([:]); return }
      var receipts: [Data] = []
      for text in ids {
        if let id = UUID(uuidString: text), let receipt = try? await self.inbox.receipt(id),
          let data = try? JSONEncoder().encode(receipt) { receipts.append(data) }
      }
      replyHandler(["daypage.receipts.v1": receipts])
    }
  }

  private func transcribePending() async {
    guard transcribes, !transcribing, UIApplication.shared.applicationState == .active,
      SFSpeechRecognizer.authorizationStatus() == .authorized,
      let recognizer = SFSpeechRecognizer(locale: .current), recognizer.supportsOnDeviceRecognition else { return }
    transcribing = true; defer { transcribing = false }
    do {
      for entry in try await store.entries() where entry.memo.device == "Apple Watch" && entry.memo.body.isEmpty {
        guard transcribes, UIApplication.shared.applicationState == .active,
          let asset = entry.memo.attachments.first(where: { $0.kind == "audio" }) else { continue }
        let url = try await store.assetURL(asset.file, for: entry)
        if let text = await recognize(url, with: recognizer), !text.isEmpty, transcribes {
          // NotebookStore's original-block check protects edits made while recognition was running.
          try await store.update(entry, body: text)
          await didChange?()
        }
      }
    } catch { status = String(localized: "The original audio is saved. Transcription can retry when you reopen DayPage.") }
  }
  private func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async -> String? {
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = false
    return await withCheckedContinuation { continuation in
      var finished = false
      let timeout = Task { @MainActor [weak self] in
        do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
        guard !finished else { return }; finished = true
        self?.recognition?.cancel(); continuation.resume(returning: nil)
      }
      recognition = recognizer.recognitionTask(with: request) { result, error in
        Task { @MainActor [weak self] in
          guard !finished, error != nil || result?.isFinal == true else { return }
          finished = true; timeout.cancel(); self?.recognition = nil
          continuation.resume(returning: error == nil ? result?.bestTranscription.formattedString : nil)
        }
      }
    }
  }
}
