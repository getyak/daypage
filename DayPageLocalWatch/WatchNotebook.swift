import AVFoundation
import DayPageCapture
import Foundation
import SwiftUI
import WatchConnectivity
import WatchKit

private struct RecordingDraft: Codable {
  let id: UUID
  let created: Date
}

@MainActor
final class WatchNotebook: NSObject, ObservableObject, WCSessionDelegate, AVAudioRecorderDelegate {
  @Published private(set) var recording = false
  @Published private(set) var saving = false
  @Published private(set) var started = Date()
  @Published private(set) var captures: [WatchCapture] = []
  @Published private(set) var delivered: Set<UUID> = []
  @Published private(set) var message = String(localized: "A thought, kept close.")
  private let root = URL.documentsDirectory.appendingPathComponent("WatchNotebook")
  private lazy var outbox = WatchCaptureStore(root: root.appendingPathComponent("outbox"))
  private var recorder: AVAudioRecorder?
  private var player: AVAudioPlayer?
  private var draft: RecordingDraft?
  private var transferring = false
  private var recovering = false

  func activate() async {
    if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    await recoverDrafts()
    await reload()
    await sendPending()
    if UserDefaults.standard.bool(forKey: "watch.startRecording") {
      UserDefaults.standard.removeObject(forKey: "watch.startRecording")
      await begin()
    }
  }
  func begin() async {
    guard !recording, !saving, !recovering else { return }
    saving = true; defer { saving = false }
    let permitted = await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
    }
    guard permitted else { message = String(localized: "Allow microphone access in Settings to record."); return }
    do {
      let directory = root.appendingPathComponent("drafts")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let current = RecordingDraft(id: UUID(), created: Date())
      let base = directory.appendingPathComponent(current.id.uuidString)
      try JSONEncoder().encode(current).write(to: base.appendingPathExtension("json"), options: .atomic)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .default)
      try session.setActive(true)
      player?.stop()
      let recorder = try AVAudioRecorder(url: base.appendingPathExtension("m4a"), settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
      ])
      recorder.delegate = self
      guard recorder.record(forDuration: 300) else { throw ReplicaError.unavailable }
      self.recorder = recorder; draft = current; started = current.created; recording = true
      message = String(localized: "Listening…")
      WKInterfaceDevice.current().play(.start)
    } catch { message = String(localized: "Could not start recording. Previous originals are safe.") }
  }
  func stop() {
    guard recording else { return }
    recording = false; saving = true; recorder?.stop()
    WKInterfaceDevice.current().play(.stop)
  }
  func play(_ capture: WatchCapture) async {
    guard !recording, !saving else { return }
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
      try AVAudioSession.sharedInstance().setActive(true)
      player = try AVAudioPlayer(contentsOf: await outbox.audioURL(capture.id))
      player?.play()
    } catch { message = String(localized: "The original is kept, but playback is unavailable.") }
  }
  private func reload() async {
    do {
      captures = try await outbox.captures()
      var received = Set<UUID>()
      for capture in captures where try await outbox.receipt(capture.id) != nil { received.insert(capture.id) }
      delivered = received
    } catch { message = error.localizedDescription }
  }
  private func recoverDrafts() async {
    guard !recording, recorder == nil, !recovering else { return }
    recovering = true; defer { recovering = false }
    let directory = root.appendingPathComponent("drafts")
    for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
      do {
        let draft = try JSONDecoder().decode(RecordingDraft.self, from: Data(contentsOf: file))
        let audio = file.deletingPathExtension().appendingPathExtension("m4a")
        let duration = try await AVURLAsset(url: audio).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { continue }
        let data = try Data(contentsOf: audio)
        let capture = WatchCapture(id: draft.id, created: draft.created, duration: duration, digest: ReplicaDigest.hash(data))
        try await outbox.stage(capture, audio: data)
        // Only these task-owned draft copies are removed, after durable canonical storage.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: audio)
      } catch { message = String(localized: "An interrupted original is kept on this Watch. Reopen to retry.") }
    }
  }
  private func sendPending() async {
    guard !transferring, WCSession.default.activationState == .activated else { return }
    transferring = true; defer { transferring = false }
    do {
      let pending = try await outbox.captures().filter { !delivered.contains($0.id) }
      let outstanding = Set(WCSession.default.outstandingFileTransfers.compactMap {
        ($0.file.metadata?["daypage.capture.v1"] as? Data).flatMap { try? JSONDecoder().decode(WatchCapture.self, from: $0) }?.id
      })
      for capture in pending where !outstanding.contains(capture.id) {
        let url = try await outbox.audioURL(capture.id)
        WCSession.default.transferFile(url, metadata: ["daypage.capture.v1": try JSONEncoder().encode(capture)])
      }
      requestReceipts(pending.map(\.id))
    } catch { message = String(localized: "Saved on Watch. Delivery will retry automatically.") }
  }
  private func requestReceipts(_ ids: [UUID]) {
    guard WCSession.default.isReachable, !ids.isEmpty else { return }
    WCSession.default.sendMessage(["daypage.receipt.request.v1": ids.prefix(100).map(\.uuidString)], replyHandler: { [weak self] reply in
      let receipts = reply["daypage.receipts.v1"] as? [Data] ?? []
      Task { @MainActor [weak self] in for data in receipts { await self?.receive(data) } }
    }, errorHandler: { _ in })
  }
  private func receive(_ data: Data) async {
    do {
      let receipt = try JSONDecoder().decode(WatchCaptureReceipt.self, from: data)
      try await outbox.markDelivered(receipt)
      await reload()
      message = String(localized: "Kept in DayPage.")
    } catch { /* An unknown/stale receipt cannot mark another original delivered. */ }
  }
  nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.recording = false; self.recorder = nil; self.draft = nil
      await self.recoverDrafts(); await self.reload()
      self.saving = false
      self.message = String(localized: "Saved on Watch. Sending automatically.")
      try? AVAudioSession.sharedInstance().setActive(false)
      await self.sendPending()
    }
  }
  nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    Task { @MainActor [weak self] in self?.stop() }
  }
  nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
    if state == .activated { Task { @MainActor [weak self] in await self?.reload(); await self?.sendPending() } }
  }
  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor [weak self] in await self?.sendPending() }
  }
  nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
    // WC transport completion is not a notebook persistence receipt.
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.requestReceipts(self.captures.filter { !self.delivered.contains($0.id) }.map(\.id))
    }
  }
  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    guard let data = userInfo["daypage.receipt.v1"] as? Data else { return }
    Task { @MainActor [weak self] in await self?.receive(data) }
  }
}
