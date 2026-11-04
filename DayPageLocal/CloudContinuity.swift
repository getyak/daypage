import DayPageCore
import Foundation
import SwiftUI

/// A revoked lease invalidates old tasks even if they still hold a container URL.
final class CloudAccountLease: @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  private let token: NSObject
  init(token: NSObject) { self.token = token }
  func revoke() { lock.lock(); active = false; lock.unlock() }
  func check() throws {
    lock.lock(); let valid = active; lock.unlock()
    guard valid, (FileManager.default.ubiquityIdentityToken as? NSObject)?.isEqual(token) == true else {
      throw CancellationError()
    }
  }
}

@MainActor
final class CloudContinuity: ObservableObject {
  @Published private(set) var enabled = false
  @Published private(set) var working = false
  @Published private(set) var status = String(localized: "Saved on this device")
  @Published private(set) var lastExchange: Date?
  @Published private(set) var history: [VaultRevision] = []
  private let store: NotebookStore
  private let root: URL
  private let defaults: UserDefaults
  private let isQA: Bool
  private var lease: CloudAccountLease?
  private var replica: VaultReplica?
  private var transport: DirectoryReplicaTransport?
  private var query: NSMetadataQuery?
  private var observers: [NSObjectProtocol] = []
  private var queryObservers: [NSObjectProtocol] = []
  private var requested = false
  private var pending: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private var generation = UUID()
  var didChange: (() async -> Void)?
  static let containerID = "iCloud.com.daypage.app"

  init(store: NotebookStore, root: URL, defaults: UserDefaults, isQA: Bool) {
    self.store = store; self.root = root; self.defaults = defaults; self.isQA = isQA
    observers.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange,
      object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in self?.accountChanged() }
      })
  }
  deinit {
    for observer in observers + queryObservers { NotificationCenter.default.removeObserver(observer) }
    pending?.cancel(); operation?.cancel(); lease?.revoke()
  }
  func start() async {
    guard defaults.bool(forKey: "continuity.enabled"), !enabled else { return }
    await setEnabled(true, restoringPreference: true)
  }
  func setEnabled(_ value: Bool, restoringPreference: Bool = false) async {
    stop()
    guard value, !isQA else {
      defaults.set(false, forKey: "continuity.enabled"); status = String(localized: "Saved on this device"); return
    }
    guard let token = FileManager.default.ubiquityIdentityToken as? NSObject,
      let archived = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
    else { status = String(localized: "Sign in to iCloud Drive in Settings, then try again."); return }
    let previous = defaults.data(forKey: "continuity.account").flatMap(Self.decodeToken)
    if restoringPreference, previous?.isEqual(token) != true {
      accountChanged(); return
    }
    let scope: String
    if previous?.isEqual(token) == true, let saved = defaults.string(forKey: "continuity.scope"), UUID(uuidString: saved) != nil {
      scope = saved
    } else { scope = UUID().uuidString }
    let lease = CloudAccountLease(token: token)
    self.lease = lease
    let generation = self.generation
    working = true; status = String(localized: "Connecting to iCloud Drive…")
    let containerID = Self.containerID
    let container = await Task.detached(priority: .utility) {
      FileManager.default.url(forUbiquityContainerIdentifier: containerID)
    }.value
    guard self.generation == generation else { return }
    working = false
    guard let container, (try? lease.check()) != nil else {
      status = String(localized: "iCloud Drive is unavailable. Local notes remain available."); return
    }
    let remote = container.appendingPathComponent("Documents/DayPageContinuity/v1")
    let state = root.deletingLastPathComponent().appendingPathComponent(".daypage-continuity/" + scope)
    replica = VaultReplica(store: store, stateRoot: state, validateSession: { try lease.check() })
    transport = DirectoryReplicaTransport(root: remote, validateSession: { try lease.check() })
    defaults.set(archived, forKey: "continuity.account"); defaults.set(scope, forKey: "continuity.scope")
    defaults.set(true, forKey: "continuity.enabled"); enabled = true
    beginDiscovery(remote)
    schedule()
  }
  func schedule() {
    guard enabled else { return }
    requested = true
    pending?.cancel()
    pending = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
      await self?.exchange()
    }
  }
  func exchange() async {
    guard enabled, !working, let replica, let transport, let lease else { return }
    let generation = self.generation
    requested = false
    var retry = false
    working = true; status = String(localized: "Exchanging notes and attachments…")
    let task = Task { [weak self] in
      do {
        try lease.check()
        try await replica.exchange(with: transport)
        let history = try await replica.history()
        guard let self, self.generation == generation else { return }
        self.history = history; self.lastExchange = Date()
        self.status = String(localized: "Local exchange complete. iCloud uploads automatically.")
        await self.didChange?()
      } catch is CancellationError { }
      catch {
        guard let self, self.generation == generation else { return }
        self.status = error.localizedDescription
        retry = true
      }
    }
    operation = task
    await task.value
    guard self.generation == generation else { return }
    working = false; operation = nil
    if requested { schedule() }
    else if retry {
      pending = Task { [weak self] in
        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
        await self?.exchange()
      }
    }
  }
  func restore(_ id: String) async {
    guard !working, enabled, let replica else { return }
    let generation = self.generation
    working = true
    do {
      try await replica.restore(id)
      guard self.generation == generation else { return }
      status = String(localized: "Recovered a separate copy. Current notes are unchanged.")
      await didChange?()
    } catch { if self.generation == generation { status = error.localizedDescription } }
    if self.generation == generation { working = false; schedule() }
  }
  private func stop() {
    generation = UUID(); lease?.revoke(); lease = nil
    pending?.cancel(); operation?.cancel(); pending = nil; operation = nil
    query?.stop(); query = nil
    for observer in queryObservers { NotificationCenter.default.removeObserver(observer) }
    queryObservers = []; requested = false
    replica = nil; transport = nil; enabled = false; working = false
    history = []; lastExchange = nil
  }
  private func accountChanged() {
    stop(); defaults.set(false, forKey: "continuity.enabled")
    status = String(localized: "Your iCloud account changed. Enable sync again to copy this device’s notes to the current account.")
  }
  private func beginDiscovery(_ root: URL) {
    let query = NSMetadataQuery()
    query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
    query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root.path + "/")
    let queryGeneration = generation
    for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
      queryObservers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.generation == queryGeneration, let query = self.query else { return }
          query.disableUpdates()
          for item in query.results.compactMap({ $0 as? NSMetadataItem }) {
            if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
              try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
          }
          query.enableUpdates(); self.schedule()
        }
      })
    }
    self.query = query; query.start()
  }
  private static func decodeToken(_ data: Data) -> NSObject? {
    guard let decoder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    decoder.requiresSecureCoding = false
    defer { decoder.finishDecoding() }
    return decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
  }
}
