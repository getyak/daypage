import DayPageCapture
import Foundation

extension WatchCaptureStore {
  public func importCapture(_ id: UUID, into store: NotebookStore) async throws -> WatchCaptureReceipt {
    if let receipt = try receipt(id) { return receipt }
    let capture = try capture(id)
    let data = try Data(contentsOf: audioURL(id))
    guard ReplicaDigest.hash(data) == capture.digest else { throw ReplicaError.invalidData }
    let entries = try await store.entries().filter { $0.namespace.isEmpty && $0.memo.id == id }
    let trashed = try await store.trashReceipts().filter { $0.entry.namespace.isEmpty && $0.entry.memo.id == id }
    guard entries.count <= 1 else { throw ReplicaError.invalidData }
    if let entry = entries.first ?? trashed.first?.entry {
      guard entry.memo.device == "Apple Watch", let asset = entry.memo.attachments.first,
        ReplicaDigest.hash(try Data(contentsOf: await store.assetURL(asset.file, for: entry))) == capture.digest
      else { throw ReplicaError.invalidData }
    } else {
      try await store.append(Memo(id: id, type: .voice, created: capture.created, device: "Apple Watch"),
        assets: [.init(data: data, fileExtension: "m4a", kind: "audio", duration: capture.duration)])
    }
    let receipt = WatchCaptureReceipt(id: id, digest: capture.digest)
    try markDelivered(receipt)
    return receipt
  }
}
