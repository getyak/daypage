import DayPageCapture
import Foundation

/// The person's explicit confirmation is the only caller of this operation.
/// A stable inbox UUID makes retry after publication safe, including trashed notes.
public enum ScreenshotNoteSaver {
  public struct Result: Sendable {
    public let alreadySaved: Bool
    public let inboxAcknowledged: Bool
  }

  public static func save(_ capture: ScreenshotCapture, caption: String,
    inbox: ScreenshotInbox, store: NotebookStore) async throws -> Result {
    guard caption.utf8.count <= 4 * 1024 * 1024 else { throw ScreenshotInboxError.tooLarge }
    let data = try await inbox.image(capture)
    var exists = try await verifiedExisting(capture, store: store)
    if !exists {
      do {
        try await store.append(Memo(id: capture.id, created: capture.created, body: caption),
          assets: [NotebookAssetInput(data: data, fileExtension: capture.kind.fileExtension, kind: "photo")])
      } catch {
        // append's coordinated global identity check wins across store actors.
        // Only acknowledge a concurrent winner after verifying its actual bytes.
        guard try await verifiedExisting(capture, store: store) else { throw error }
        exists = true
      }
    }
    // Raw publication is the commit point. Cleanup failure must not claim the
    // note failed or encourage another identity. The pending envelope is retained.
    do {
      try await inbox.remove(capture)
      return Result(alreadySaved: exists, inboxAcknowledged: true)
    } catch {
      return Result(alreadySaved: exists, inboxAcknowledged: false)
    }
  }

  private static func verifiedExisting(_ capture: ScreenshotCapture, store: NotebookStore) async throws -> Bool {
    let current = try await store.entries().filter { $0.namespace.isEmpty && $0.memo.id == capture.id }
    let deleted = try await store.trashReceipts().map(\.entry).filter { $0.namespace.isEmpty && $0.memo.id == capture.id }
    let matches = current + deleted
    guard !matches.isEmpty else { return false }
    guard matches.count == 1 else { throw ScreenshotInboxError.changed }
    for attachment in matches[0].memo.attachments where attachment.kind == "photo" {
      let url = try await store.assetURL(attachment.file, for: matches[0])
      let digest = try await Task.detached(priority: .utility) {
        ReplicaDigest.hash(try ScreenshotInbox.readImageFile(url))
      }.value
      if digest == capture.digest { return true }
    }
    // A matching UUID without the original photo is not a delivery receipt.
    throw ScreenshotInboxError.changed
  }
}
