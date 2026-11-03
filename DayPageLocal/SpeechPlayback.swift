import AVFoundation
import DayPageCore
import SwiftUI
import UIKit

/// Explicit, foreground-only playback. The shared audio lease never carries preferences or keys.
@MainActor
final class SpeechPlayback: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
  @Published private(set) var isSpeaking = false
  @Published private(set) var isPreparing = false
  @Published private(set) var isPaused = false
  @Published private(set) var error: String?
  @Published private(set) var status: String?
  @Published private(set) var channelName: String?
  @Published private(set) var requestID: String?
  private let defaults: UserDefaults
  private let synthesizer = AVSpeechSynthesizer()
  private var player: AVAudioPlayer?
  private var utterance: AVSpeechUtterance?
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private var activeID: String?
  private var ownsAudioSession = false
  private var notifications: [NSObjectProtocol] = []
  private static weak var owner: SpeechPlayback?
  private static weak var recordingOwner: AnyObject?

  init(defaults: UserDefaults) {
    self.defaults = defaults
    super.init()
    synthesizer.delegate = self
    notifications.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
      Task { @MainActor [weak self] in self?.stop() }
    })
    notifications.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
      guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
      Task { @MainActor [weak self] in self?.stop() }
    })
    notifications.append(NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor [weak self] in self?.stop() } })
  }

  deinit {
    task?.cancel()
    synthesizer.stopSpeaking(at: .immediate)
    player?.stop()
    for notification in notifications { NotificationCenter.default.removeObserver(notification) }
    let hadSession = ownsAudioSession
    Task { @MainActor in
      if hadSession, SpeechPlayback.owner == nil, SpeechPlayback.recordingOwner == nil {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      }
    }
  }

  /// Called by the recorder only after it acquires its own recording lease.
  static func recordingWillStart(_ recorder: AnyObject) {
    owner?.stop()
    recordingOwner = recorder
  }
  static func recordingDidEnd(_ recorder: AnyObject) {
    if recordingOwner === recorder { recordingOwner = nil }
  }

  func isActive(id: String) -> Bool { activeID == id && (isSpeaking || isPreparing || isPaused) }

  func speak(_ text: String, id: String) {
    stop()
    requestID = id
    channelName = nil
    do {
      guard let channel = try SpeechPreferencesStore(defaults: defaults).loadValidated().selectedChannel else {
        throw SpeechError.configuration
      }
      channelName = displayName(channel)
      let key = try SpeechSecretStore.read(channel: channel)
      start(text, id: id, channel: channel, key: key)
    } catch { report(error) }
  }

  /// The editor previews its current draft without changing the saved playback selection.
  func preview(_ text: String, channel: SpeechChannel, apiKey: String) {
    stop()
    requestID = "speech-preview"
    channelName = displayName(channel)
    start(text, id: "speech-preview", channel: channel,
      key: channel.requiresAuthentication ? apiKey : "")
  }

  func stop() {
    generation = UUID()
    task?.cancel()
    task = nil
    utterance = nil
    synthesizer.stopSpeaking(at: .immediate)
    player?.delegate = nil
    player?.stop()
    player = nil
    isPreparing = false
    isSpeaking = false
    isPaused = false
    activeID = nil
    status = nil
    releaseAudioSession()
  }

  func pause() {
    guard isSpeaking, !isPreparing else { return }
    if player != nil { player?.pause() }
    else if !synthesizer.pauseSpeaking(at: .immediate) { stop(); return }
    isSpeaking = false
    isPaused = true
    status = String(localized: "Speech paused")
    releaseAudioSession()
  }

  func resume() {
    guard isPaused else { return }
    do {
      try acquireAudioSession()
      if let player {
        guard player.play() else { throw SpeechError.playback }
      } else {
        guard synthesizer.continueSpeaking() else { throw SpeechError.playback }
      }
      isPaused = false
      isSpeaking = true
      status = String(localized: "Reading aloud")
    } catch { stop(); report(error) }
  }

  private func start(_ text: String, id: String, channel: SpeechChannel, key: String) {
    error = nil
    do {
      guard Self.recordingOwner == nil else { throw SpeechError.microphoneInUse }
      _ = try channel.validated()
      try SpeechRequest.validateText(text)
      Self.owner?.stop()
      Self.owner = self
      activeID = id
      channelName = displayName(channel)
      let token = generation
      if channel.provider == .system {
        try acquireAudioSession()
        let utterance = AVSpeechUtterance(string: text)
        if !channel.voice.isEmpty {
          guard let voice = AVSpeechSynthesisVoice(identifier: channel.voice) else { throw SpeechError.configuration }
          utterance.voice = voice
        } else {
          utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier)
        }
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
          max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(channel.speed)))
        self.utterance = utterance
        isSpeaking = true
        status = String(localized: "Reading aloud")
        synthesizer.speak(utterance)
      } else {
        let request = try SpeechRequest.make(channel: channel, text: text, apiKey: key)
        isPreparing = true
        status = String(localized: "Preparing speech…")
        task = Task { [weak self] in
          do {
            let data = try await SpeechTransport().data(for: request)
            try Task.checkCancellation()
            guard let self, self.generation == token, Self.owner === self else { return }
            let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
            guard player.prepareToPlay() else { throw SpeechError.playback }
            try self.acquireAudioSession()
            player.delegate = self
            self.player = player
            guard player.play() else { throw SpeechError.playback }
            self.isPreparing = false
            self.isSpeaking = true
            self.status = String(localized: "Reading aloud")
            self.task = nil
          } catch {
            guard let self, self.generation == token else { return }
            self.stop()
            if !(error is CancellationError) { self.report(error) }
          }
        }
      }
    } catch { stop(); report(error) }
  }

  private func acquireAudioSession() throws {
    guard Self.recordingOwner == nil else { throw SpeechError.microphoneInUse }
    guard Self.owner == nil || Self.owner === self else { throw SpeechError.playback }
    Self.owner = self
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    try session.setActive(true)
    ownsAudioSession = true
  }
  private func releaseAudioSession() {
    if ownsAudioSession, Self.owner === self, Self.recordingOwner == nil {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    ownsAudioSession = false
    if Self.owner === self { Self.owner = nil }
  }
  private func report(_ error: Error) {
    let speech = error as? SpeechError ?? .playback
    self.error = NSLocalizedString(speech.localizedDescription, comment: "Speech error")
  }
  private func displayName(_ channel: SpeechChannel) -> String {
    channel.provider == .system && channel.name == SpeechProvider.system.name
      ? String(localized: "System speech") : channel.name
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in
      guard let self, self.utterance === utterance else { return }
      self.stop()
    }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in
      guard let self, self.utterance === utterance else { return }
      self.stop()
    }
  }
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor [weak self] in
      guard let self, self.player === player else { return }
      self.stop()
      if !flag { self.report(SpeechError.playback) }
    }
  }
  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    Task { @MainActor [weak self] in
      guard let self, self.player === player else { return }
      self.stop()
      self.report(SpeechError.playback)
    }
  }
}
