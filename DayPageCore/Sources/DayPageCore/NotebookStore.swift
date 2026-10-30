import Foundation

public struct NotebookEntry: Identifiable, Equatable, Sendable {
  public let memo: Memo
  public let day: String
  public let namespace: String
  fileprivate let originalMarkdown: String?
  fileprivate let originRoot: URL?
  public var id: String { "\(namespace)/\(day)/\(memo.id.uuidString)" }
  public init(memo: Memo, day: String, namespace: String = "") {
    self.memo = memo
    self.day = day
    self.namespace = namespace
    originalMarkdown = nil
    originRoot = nil
  }
  fileprivate init(memo: Memo, day: String, namespace: String, originalMarkdown: String, originRoot: URL) {
    self.memo = memo
    self.day = day
    self.namespace = namespace
    self.originalMarkdown = originalMarkdown
    self.originRoot = originRoot
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.memo == rhs.memo && lhs.day == rhs.day && lhs.namespace == rhs.namespace
  }
}

public struct NotebookAssetInput: Sendable {
  public let data: Data
  public let fileExtension: String
  public let kind: String
  public let duration: Double?

  public init(data: Data, fileExtension: String, kind: String, duration: Double? = nil) {
    self.data = data
    self.fileExtension = fileExtension
    self.kind = kind
    self.duration = duration
  }
}

public struct NotebookTrashReceipt: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let entry: NotebookEntry
  fileprivate let origin: UUID
  fileprivate let originRoot: URL
}

private struct TrashManifest: Codable {
  let version: Int
  let origin: UUID
  let namespace: String
  let day: String
  let memoID: UUID
  let index: Int
  let created: Date
}

private struct TrashRecord {
  let manifest: TrashManifest
  let original: DayDocument
  let receipt: NotebookTrashReceipt
}

public enum NotebookError: LocalizedError {
  case invalidPath, emptyNote, conflict, ambiguousRecord, invalidVault, unreadableFile,
    reservedSeparator, invalidAsset
  public var errorDescription: String? {
    switch self {
    case .invalidPath: return "The file path is not inside this notebook."
    case .emptyNote: return "Write something before saving."
    case .conflict: return "This note changed elsewhere. Reopen it before editing."
    case .ambiguousRecord:
      return "This file needs attention. Its original content has been preserved."
    case .invalidVault:
      return
        "Choose a downloaded Vault folder containing a raw folder. Linked files cannot be imported."
    case .unreadableFile:
      return "Some records could not be read. Their original files have not been changed."
    case .reservedSeparator:
      return
        "This text contains a reserved record separator. Remove that separator before saving; your draft has been kept."
    case .invalidAsset:
      return "Use up to 10 nonempty attachments, each no larger than 25 MB, with a valid file type."
    }
  }
}

/// Keeps the original record blocks, including unknown YAML and spacing.
private struct DayDocument {
  static let modern = "\n\n<!-- daypage-memo-separator -->\n\n"
  static let legacy = "\n\n---\n\n"
  var blocks: [String]
  let separator: String
  init(_ content: String) {
    if content.contains(Self.modern) {
      blocks = content.components(separatedBy: Self.modern)
      separator = Self.modern
    } else if content.contains(Self.legacy) {
      let candidates = content.components(separatedBy: Self.legacy)
      let nonempty = candidates.filter {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      if !nonempty.isEmpty && nonempty.allSatisfy({ Memo.fromMarkdown($0) != nil }) {
        blocks = candidates
        separator = Self.legacy
      } else {
        blocks = content.isEmpty ? [] : [content]
        separator = Self.modern
      }
    } else {
      blocks = content.isEmpty ? [] : [content]
      separator = Self.modern
    }
  }
  var content: String { blocks.joined(separator: separator) }
  var valid: Bool {
    blocks.allSatisfy {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Memo.fromMarkdown($0) != nil
    }
  }
}

public actor NotebookStore {
  public let root: URL
  private let fm = FileManager.default
  public init(root: URL) { self.root = root.standardizedFileURL }

  public func entries() throws -> [NotebookEntry] {
    try readEntries(in: root)
  }

  private func readEntries(in searchRoot: URL) throws -> [NotebookEntry] {
    var locations: [(URL, String)] = [(searchRoot, "")]
    var result: [NotebookEntry] = []
    var cursor = 0
    while cursor < locations.count {
      guard locations.count <= 1000 else { throw NotebookError.invalidVault }
      let (vault, namespace) = locations[cursor]
      cursor += 1
      let imports = vault.appendingPathComponent("imports")
      if fm.fileExists(atPath: imports.path) {
        try validateContained(imports, within: searchRoot)
        for folder in try fm.contentsOfDirectory(
          at: imports, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        where UUID(uuidString: folder.lastPathComponent) != nil {
          let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          guard values.isSymbolicLink != true, values.isDirectory == true,
            namespace.split(separator: "/").count < 16
          else { throw NotebookError.invalidVault }
          locations.append(
            (
              folder,
              namespace.isEmpty
                ? folder.lastPathComponent : namespace + "/" + folder.lastPathComponent
            ))
        }
      }
      let raw = vault.appendingPathComponent("raw")
      guard fm.fileExists(atPath: raw.path) else { continue }
      try validateContained(raw, within: searchRoot)
      for url in try fm.contentsOfDirectory(
        at: raw, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      {
        guard url.pathExtension == "md",
          Self.validDay(url.deletingPathExtension().lastPathComponent)
        else { continue }
        try validateContained(url, within: searchRoot)
        let document = DayDocument(try String(contentsOf: url, encoding: .utf8))
        guard document.valid else { throw NotebookError.unreadableFile }
        result += document.blocks.compactMap { block in
          Memo.fromMarkdown(block).map {
            NotebookEntry(memo: $0, day: url.deletingPathExtension().lastPathComponent,
              namespace: namespace, originalMarkdown: block, originRoot: root)
          }
        }
      }
    }
    guard Set(result.map(\.id)).count == result.count else { throw NotebookError.ambiguousRecord }
    return result.sorted {
      $0.memo.created == $1.memo.created ? $0.id < $1.id : $0.memo.created > $1.memo.created
    }
  }

  public func append(_ memo: Memo) throws {
    try append(memo, assets: [])
  }

  /// Publishes generated assets and their Markdown record as one coordinated operation.
  /// Existing attachments retain their original paths and metadata.
  public func append(_ memo: Memo, assets: [NotebookAssetInput]) throws {
    guard assets.count <= 10 else { throw NotebookError.invalidAsset }
    for asset in assets {
      guard !asset.data.isEmpty, asset.data.count <= 25 * 1024 * 1024,
        asset.fileExtension.range(of: #"^[A-Za-z0-9]{1,12}$"#, options: .regularExpression) != nil,
        ["photo", "audio", "file"].contains(asset.kind),
        asset.duration.map({ $0.isFinite && $0 >= 0 && asset.kind == "audio" }) ?? true
      else { throw NotebookError.invalidAsset }
    }
    guard !memo.body.contains(DayDocument.modern) else { throw NotebookError.reservedSeparator }
    guard
      !memo.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !memo.attachments.isEmpty || !assets.isEmpty
    else { throw NotebookError.emptyNote }
    let date = DateFormatter()
    date.calendar = Calendar(identifier: .gregorian)
    date.locale = Locale(identifier: "en_US_POSIX")
    date.dateFormat = "yyyy-MM-dd"
    let url = root.appendingPathComponent("raw/\(date.string(from: memo.created)).md")
    try validateContained(url)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try coordinatedWrite(at: url) { coordinated in
      let existing =
        self.fm.fileExists(atPath: coordinated.path)
        ? try String(contentsOf: coordinated, encoding: .utf8) : ""
      var document = DayDocument(existing)
      guard document.valid else { throw NotebookError.ambiguousRecord }
      try self.requireIdentityCount(memo.id, namespace: "", count: 0)
      var saved = memo
      let generated = assets.map { asset in
        (asset, "\(UUID().uuidString).\(asset.fileExtension.lowercased())")
      }
      saved.attachments += generated.map { asset, filename in
        Memo.Attachment(file: "raw/assets/" + filename, kind: asset.kind, duration: asset.duration)
      }
      if !assets.isEmpty {
        let kinds = Set(saved.attachments.map(\.kind))
        saved.type = kinds == ["photo"] ? .photo : kinds == ["audio"] ? .voice : .mixed
      }
      let expected = document.blocks.compactMap(Memo.fromMarkdown).map(\.id) + [memo.id]
      document.blocks.append(saved.toMarkdown())
      try self.validateEncoding(document, expected: expected)
      let assetsFolder = self.root.appendingPathComponent("raw/assets")
      let staging = self.root.appendingPathComponent(".daypage-assets-\(UUID())")
      var published: [URL] = []
      var committed = false
      defer {
        if !committed {
          for url in published {
            if (try? self.validateContained(url)) != nil { try? self.fm.removeItem(at: url) }
          }
        }
        if !generated.isEmpty { try? self.fm.removeItem(at: staging) }
      }
      if !generated.isEmpty {
        try self.validateContained(assetsFolder)
        try self.fm.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
        try self.validateContained(staging)
        try self.fm.createDirectory(at: staging, withIntermediateDirectories: false)
        for (asset, filename) in generated {
          let temporary = staging.appendingPathComponent(filename)
          try asset.data.write(to: temporary, options: .atomic)
          let destination = assetsFolder.appendingPathComponent(filename)
          try self.validateContained(destination)
          // moveItem fails if a destination already exists; no original is overwritten.
          try self.fm.moveItem(at: temporary, to: destination)
          published.append(destination)
        }
      }
      try self.validateContained(coordinated)
      try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
      committed = true
    }
  }

  public func update(_ entry: NotebookEntry, body: String) throws {
    guard !body.contains(DayDocument.modern) else { throw NotebookError.reservedSeparator }
    guard
      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !entry.memo.attachments.isEmpty
    else { throw NotebookError.emptyNote }
    let url = try fileURL(for: entry)
    try coordinatedWrite(at: url) { coordinated in
      var (document, index) = try self.target(entry, at: coordinated)
      let block = document.blocks[index]
      guard let opening = block.range(of: "---\n"),
        let closing = block.range(of: "\n---", range: opening.upperBound..<block.endIndex)
      else { throw NotebookError.ambiguousRecord }
      // Preserve unknown YAML fields and every untargeted record's bytes.
      let expected = document.blocks.compactMap(Memo.fromMarkdown).map(\.id)
      document.blocks[index] = String(block[..<closing.upperBound]) + "\n\n" + body
      try self.validateEncoding(document, expected: expected)
      try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
    }
  }

  public func setPinned(_ entry: NotebookEntry, pinned: Bool) throws {
    let url = try fileURL(for: entry)
    try coordinatedWrite(at: url) { coordinated in
      var (document, index) = try self.target(entry, at: coordinated)
      guard (entry.memo.pinnedAt != nil) != pinned else { return }
      let block = document.blocks[index]
      let header = try self.frontmatterRange(in: block)
      var lines = String(block[header]).components(separatedBy: "\n")
      let existing = lines.indices.filter { lines[$0].hasPrefix("pinned_at:") }
      guard existing.count <= 1 else { throw NotebookError.ambiguousRecord }
      if let old = existing.first { lines.remove(at: old) }
      if pinned { lines.insert("pinned_at: " + ISO8601DateFormatter.memo.string(from: Date()), at: 0) }
      document.blocks[index] = String(block[..<header.lowerBound]) + lines.joined(separator: "\n") + String(block[header.upperBound...])
      try self.validateEncoding(document, expected: document.blocks.compactMap(Memo.fromMarkdown).map(\.id))
      guard (Memo.fromMarkdown(document.blocks[index])?.pinnedAt != nil) == pinned else {
        throw NotebookError.ambiguousRecord
      }
      try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
    }
  }

  /// Moves only the selected record into a recoverable hidden backup. Assets stay in place.
  public func trash(_ entry: NotebookEntry) throws -> NotebookTrashReceipt {
    let url = try fileURL(for: entry)
    var result: NotebookTrashReceipt?
    try coordinatedWrite(at: url) { coordinated in
      var (document, index) = try self.target(entry, at: coordinated)
      try self.finishPendingRestores(for: entry)
      let original = document.content
      let block = document.blocks.remove(at: index)
      try self.validateEncoding(document, expected: document.blocks.compactMap(Memo.fromMarkdown).map(\.id))
      let origin = try self.trashOrigin(create: true)
      let id = UUID()
      let folder = self.trashFolder(id)
      try self.validateContained(folder)
      try self.fm.createDirectory(at: folder, withIntermediateDirectories: false)
      var committed = false
      defer { if !committed { try? self.fm.removeItem(at: folder) } }
      let manifest = TrashManifest(version: 1, origin: origin, namespace: entry.namespace,
        day: entry.day, memoID: entry.memo.id, index: index, created: Date())
      try original.write(to: folder.appendingPathComponent("original.md"), atomically: true, encoding: .utf8)
      try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
      let deleting = folder.appendingPathComponent("deleting")
      try Data().write(to: deleting, options: .atomic)
      try self.validateContained(coordinated)
      try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
      committed = true
      // Keep deletion's commit separate from its prepared backup. If finalizing this
      // journal is interrupted, readback reconciles it against the original raw block.
      try? self.fm.moveItem(at: deleting, to: folder.appendingPathComponent("deleted"))
      let saved = NotebookEntry(memo: entry.memo, day: entry.day, namespace: entry.namespace,
        originalMarkdown: block, originRoot: self.root)
      result = NotebookTrashReceipt(id: id, entry: saved, origin: origin, originRoot: self.root)
    }
    guard let result else { throw NotebookError.unreadableFile }
    return result
  }

  /// Reads validated, unconsumed recovery records after an app restart.
  public func trashReceipts() throws -> [NotebookTrashReceipt] {
    let directory = root.appendingPathComponent(".daypage-trash")
    try validateContained(directory)
    guard fm.fileExists(atPath: directory.path) else { return [] }
    let origin = try trashOrigin(create: false)
    var records: [TrashRecord] = []
    for listed in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      guard let id = UUID(uuidString: listed.lastPathComponent) else { continue }
      let folder = trashFolder(id)
      try validateContained(folder)
      let restored = folder.appendingPathComponent("restored")
      try validateContained(restored)
      if fm.fileExists(atPath: restored.path) { continue }
      let manifest = folder.appendingPathComponent("manifest.json")
      try validateContained(manifest)
      // Raw deletion is ordered after the completed manifest; incomplete preparations
      // therefore cannot be real deletions. Keep their backups without publishing them.
      guard fm.fileExists(atPath: manifest.path) else { continue }
      let record = try readTrash(id, origin: origin)
      var committed = false
      try coordinatedWrite(at: fileURL(for: record.receipt.entry)) { coordinated in
        committed = try self.trashWasCommitted(record, at: coordinated)
      }
      guard committed else { continue }
      let pending = folder.appendingPathComponent("restoring")
      try validateContained(pending)
      if fm.fileExists(atPath: pending.path),
        try readEntries(in: root).contains(where: {
          $0.namespace == record.receipt.entry.namespace && $0.memo.id == record.receipt.entry.memo.id
        })
      {
        try? fm.moveItem(at: pending, to: restored)
        continue
      }
      records.append(record)
    }
    return records.sorted { $0.manifest.created > $1.manifest.created }.map(\.receipt)
  }

  public func restore(_ receipt: NotebookTrashReceipt) throws {
    guard receipt.originRoot == root else { throw NotebookError.invalidPath }
    let url = try fileURL(for: receipt.entry)
    try coordinatedWrite(at: url) { coordinated in
      let record = try self.readTrash(receipt.id, origin: self.trashOrigin(create: false))
      guard record.receipt.origin == receipt.origin, record.receipt.entry == receipt.entry,
        let saved = record.receipt.entry.originalMarkdown, let original = receipt.entry.originalMarkdown,
        saved.utf8.elementsEqual(original.utf8)
      else { throw NotebookError.conflict }
      let folder = self.trashFolder(receipt.id)
      let restored = folder.appendingPathComponent("restored")
      try self.validateContained(restored)
      guard !self.fm.fileExists(atPath: restored.path) else { throw NotebookError.conflict }
      guard try self.trashWasCommitted(record, at: coordinated) else { throw NotebookError.conflict }
      // An imported namespace must still exist; undo never recreates a removed namespace.
      let vault = try self.vaultURL(namespace: receipt.entry.namespace)
      guard self.fm.fileExists(atPath: vault.appendingPathComponent("raw").path) else {
        throw NotebookError.conflict
      }
      try self.requireIdentityCount(receipt.entry.memo.id, namespace: receipt.entry.namespace, count: 0)
      let content = self.fm.fileExists(atPath: coordinated.path)
        ? try String(contentsOf: coordinated, encoding: .utf8) : ""
      var current = DayDocument(content)
      guard current.valid else { throw NotebookError.ambiguousRecord }
      var remainder = record.original
      let block = remainder.blocks.remove(at: record.manifest.index)
      if content.utf8.elementsEqual(remainder.content.utf8) {
        current = record.original
      } else {
        current.blocks.insert(block, at: min(record.manifest.index, current.blocks.count))
      }
      try self.validateEncoding(current, expected: current.blocks.compactMap(Memo.fromMarkdown).map(\.id))
      let pending = folder.appendingPathComponent("restoring")
      try self.validateContained(pending)
      // Preflight recovery metadata before changing Markdown. An interrupted journal is
      // resolved against the live identity when Recently Deleted is opened again.
      try Data().write(to: pending, options: .atomic)
      var committed = false
      defer { if !committed { try? self.fm.removeItem(at: pending) } }
      try self.validateContained(coordinated)
      try current.content.write(to: coordinated, atomically: true, encoding: .utf8)
      committed = true
      // The original backup is retained even after recovery; no permanent-delete API exists.
      try? self.fm.moveItem(at: pending, to: restored)
    }
  }

  /// Copies only into a new namespace; originals and existing local notes are untouched.
  public func importVault(from source: URL) throws {
    let original = source.standardizedFileURL
    guard original != root, !original.path.hasPrefix(root.path + "/"),
      fm.fileExists(atPath: original.appendingPathComponent("raw").path)
        || fm.fileExists(atPath: original.appendingPathComponent("imports").path)
    else { throw NotebookError.invalidVault }
    let keys: Set<URLResourceKey> = [
      .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]
    guard (try original.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
      let enumerator = fm.enumerator(at: original, includingPropertiesForKeys: Array(keys))
    else { throw NotebookError.invalidVault }
    for case let file as URL in enumerator {
      let values = try file.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true,
        !(values.isUbiquitousItem == true
          && values.ubiquitousItemDownloadingStatus == .notDownloaded)
      else { throw NotebookError.invalidVault }
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let staging = root.appendingPathComponent(".import-\(UUID())")
    defer { if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) } }
    try fm.copyItem(at: original, to: staging)
    _ = try readEntries(in: staging)
    let imports = root.appendingPathComponent("imports")
    try fm.createDirectory(at: imports, withIntermediateDirectories: true)
    try fm.moveItem(at: staging, to: imports.appendingPathComponent(UUID().uuidString))
  }

  public func assetURL(_ path: String, for entry: NotebookEntry) throws -> URL {
    guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
      throw NotebookError.invalidPath
    }
    let base = try vaultURL(namespace: entry.namespace)
    let relative = path.hasPrefix("raw/assets/") ? path : "raw/assets/" + path
    let url = base.appendingPathComponent(relative).standardizedFileURL
    guard url.path.hasPrefix(base.appendingPathComponent("raw/assets").path + "/") else {
      throw NotebookError.invalidPath
    }
    try validateContained(url)
    return url
  }

  private func target(_ entry: NotebookEntry, at url: URL) throws -> (DayDocument, Int) {
    let document = DayDocument(try String(contentsOf: url, encoding: .utf8))
    guard document.valid else { throw NotebookError.ambiguousRecord }
    try requireIdentityCount(entry.memo.id, namespace: entry.namespace, count: 1)
    let matches = document.blocks.indices.filter {
      Memo.fromMarkdown(document.blocks[$0])?.id == entry.memo.id
    }
    guard matches.count == 1, let index = matches.first else { throw NotebookError.ambiguousRecord }
    guard Memo.fromMarkdown(document.blocks[index]) == entry.memo,
      entry.originalMarkdown.map({ $0.utf8.elementsEqual(document.blocks[index].utf8) }) ?? true
    else { throw NotebookError.conflict }
    return (document, index)
  }

  private func requireIdentityCount(_ id: UUID, namespace: String, count: Int) throws {
    let matching = try readEntries(in: root).filter { $0.namespace == namespace && $0.memo.id == id }
    guard matching.count == count else { throw NotebookError.conflict }
  }

  private func frontmatterRange(in block: String) throws -> Range<String.Index> {
    let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
    guard let opening = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
      lines[opening].trimmingCharacters(in: .whitespaces) == "---",
      let closing = lines.indices.dropFirst(opening + 1).first(where: {
        lines[$0].trimmingCharacters(in: .whitespaces) == "---"
      }), lines[opening].endIndex < block.endIndex
    else { throw NotebookError.ambiguousRecord }
    return block.index(after: lines[opening].endIndex)..<lines[closing].startIndex
  }

  private func trashFolder(_ id: UUID) -> URL {
    root.appendingPathComponent(".daypage-trash/\(id.uuidString)")
  }

  /// Called while the affected raw file is coordinated, so another Store cannot
  /// mistake an in-flight preparation for an abandoned deletion.
  private func trashWasCommitted(_ record: TrashRecord, at url: URL) throws -> Bool {
    let folder = trashFolder(record.receipt.id)
    let deleted = folder.appendingPathComponent("deleted")
    let cancelled = folder.appendingPathComponent("cancelled")
    let deleting = folder.appendingPathComponent("deleting")
    for marker in [deleted, cancelled, deleting] { try validateContained(marker) }
    // A completed deletion stays recoverable even if its exact UUID/body is reintroduced.
    if fm.fileExists(atPath: deleted.path) { return true }
    if fm.fileExists(atPath: cancelled.path) { return false }
    let content = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
    let current = DayDocument(content)
    guard current.valid else { throw NotebookError.unreadableFile }
    let matches = current.blocks.filter { Memo.fromMarkdown($0)?.id == record.manifest.memoID }
    let original = record.original.blocks[record.manifest.index]
    if matches.count == 1, let active = matches.first, active.utf8.elementsEqual(original.utf8) {
      // The original record never left raw. Persist cancellation so later edits or
      // removal of that active record cannot resurrect this abandoned preparation.
      try Data().write(to: cancelled, options: .atomic)
      return false
    }
    if matches.isEmpty {
      if fm.fileExists(atPath: deleting.path) {
        try fm.moveItem(at: deleting, to: deleted)
      } else {
        try Data().write(to: deleted, options: .atomic)
      }
    }
    // A changed/ambiguous active identity keeps its backup visible as a conflict.
    return true
  }

  private func finishPendingRestores(for entry: NotebookEntry) throws {
    let directory = root.appendingPathComponent(".daypage-trash")
    try validateContained(directory)
    guard fm.fileExists(atPath: directory.path) else { return }
    let origin = try trashOrigin(create: false)
    for listed in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      guard let id = UUID(uuidString: listed.lastPathComponent) else { continue }
      let folder = trashFolder(id)
      let pending = folder.appendingPathComponent("restoring")
      let restored = folder.appendingPathComponent("restored")
      try validateContained(pending)
      try validateContained(restored)
      guard fm.fileExists(atPath: pending.path), !fm.fileExists(atPath: restored.path) else { continue }
      let record = try readTrash(id, origin: origin)
      if record.receipt.entry.id == entry.id {
        try fm.moveItem(at: pending, to: restored)
      }
    }
  }

  private func trashOrigin(create: Bool) throws -> UUID {
    let directory = root.appendingPathComponent(".daypage-trash")
    let marker = directory.appendingPathComponent(".origin")
    try validateContained(marker)
    if create {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      if !fm.fileExists(atPath: marker.path) {
        do {
          try Data(UUID().uuidString.utf8).write(to: marker, options: .withoutOverwriting)
        } catch {
          guard fm.fileExists(atPath: marker.path) else { throw error }
        }
      }
    }
    try validateContained(marker)
    guard let origin = UUID(uuidString: try String(contentsOf: marker, encoding: .utf8)) else {
      throw NotebookError.unreadableFile
    }
    return origin
  }

  private func readTrash(_ id: UUID, origin: UUID) throws -> TrashRecord {
    let folder = trashFolder(id)
    let manifestURL = folder.appendingPathComponent("manifest.json")
    let originalURL = folder.appendingPathComponent("original.md")
    try validateContained(manifestURL)
    try validateContained(originalURL)
    let manifest = try JSONDecoder().decode(TrashManifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.version == 1, manifest.origin == origin, Self.validDay(manifest.day),
      manifest.index >= 0
    else { throw NotebookError.invalidPath }
    // Validate the namespace before exposing any recovered entry to the app.
    let vault = try vaultURL(namespace: manifest.namespace)
    try validateContained(vault.appendingPathComponent("raw/\(manifest.day).md"))
    let original = DayDocument(try String(contentsOf: originalURL, encoding: .utf8))
    let ids = original.blocks.compactMap(Memo.fromMarkdown).map(\.id)
    guard original.valid, original.blocks.indices.contains(manifest.index),
      Set(ids).count == ids.count,
      let memo = Memo.fromMarkdown(original.blocks[manifest.index]), memo.id == manifest.memoID
    else { throw NotebookError.unreadableFile }
    let entry = NotebookEntry(memo: memo, day: manifest.day, namespace: manifest.namespace,
      originalMarkdown: original.blocks[manifest.index], originRoot: root)
    return TrashRecord(manifest: manifest, original: original,
      receipt: NotebookTrashReceipt(id: id, entry: entry, origin: origin, originRoot: root))
  }

  private func fileURL(for entry: NotebookEntry) throws -> URL {
    guard Self.validDay(entry.day) else { throw NotebookError.invalidPath }
    if let origin = entry.originRoot, origin != root { throw NotebookError.invalidPath }
    let url = try vaultURL(namespace: entry.namespace).appendingPathComponent("raw/\(entry.day).md")
    try validateContained(url)
    return url
  }
  private func vaultURL(namespace: String) throws -> URL {
    if namespace.isEmpty { return root }
    let parts = namespace.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count <= 16, parts.allSatisfy({ UUID(uuidString: String($0)) != nil }) else {
      throw NotebookError.invalidPath
    }
    return parts.reduce(root) { $0.appendingPathComponent("imports/" + $1) }
  }
  private func validateEncoding(_ document: DayDocument, expected: [UUID]) throws {
    let candidate = DayDocument(document.content)
    guard candidate.valid, candidate.blocks.compactMap(Memo.fromMarkdown).map(\.id) == expected
    else { throw NotebookError.reservedSeparator }
  }
  /// Coordinates the entire transaction with Files and other store instances,
  /// rather than coordinating only the final atomic replacement.
  private func coordinatedWrite(at url: URL, operation: (URL) throws -> Void) throws {
    var coordinationError: NSError?
    var operationError: Error?
    var performed = false
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url, options: .forMerging, error: &coordinationError
    ) { coordinated in
      performed = true
      do {
        try self.validateContained(coordinated)
        try operation(coordinated)
      } catch { operationError = error }
    }
    if let operationError { throw operationError }
    if let coordinationError { throw coordinationError }
    guard performed else { throw NotebookError.unreadableFile }
  }
  private func validateContained(_ url: URL, within allowedRoot: URL? = nil) throws {
    let requestedBase = (allowedRoot ?? root).standardizedFileURL
    let candidate = url.standardizedFileURL
    if let attributes = try? fm.attributesOfItem(atPath: requestedBase.path),
      attributes[.type] as? FileAttributeType == .typeSymbolicLink
    { throw NotebookError.invalidPath }
    // Directory enumeration canonicalizes system ancestors such as /var → /private/var.
    let base = candidate.path.hasPrefix(requestedBase.path + "/")
      ? requestedBase : requestedBase.resolvingSymlinksInPath().standardizedFileURL
    guard candidate.path.hasPrefix(base.path + "/") else { throw NotebookError.invalidPath }
    // Reject links even when they resolve inside the notebook, including dangling links.
    var path = candidate
    while path.path.hasPrefix(base.path + "/") || path == base {
      do {
        let attributes = try fm.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
          throw NotebookError.invalidPath
        }
      } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
        // New files and directories are validated through their existing ancestors.
      }
      if path == base { break }
      path.deleteLastPathComponent()
    }
    let resolvedRoot = base.resolvingSymlinksInPath().standardizedFileURL.path
    let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolved.hasPrefix(resolvedRoot + "/") else { throw NotebookError.invalidPath }
  }
  private static func validDay(_ day: String) -> Bool {
    guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
      return false
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: day) else { return false }
    return formatter.string(from: date) == day
  }
}
