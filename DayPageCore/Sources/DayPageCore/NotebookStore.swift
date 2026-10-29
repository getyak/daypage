import Foundation

public struct NotebookEntry: Identifiable, Equatable, Sendable {
  public let memo: Memo
  public let day: String
  public let namespace: String
  public var id: String { "\(namespace)/\(day)/\(memo.id.uuidString)" }
  public init(memo: Memo, day: String, namespace: String = "") {
    self.memo = memo
    self.day = day
    self.namespace = namespace
  }
}

public enum NotebookError: LocalizedError {
  case invalidPath, emptyNote, conflict, ambiguousRecord, invalidVault, unreadableFile,
    reservedSeparator
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
        result += document.blocks.compactMap(Memo.fromMarkdown).map {
          NotebookEntry(
            memo: $0, day: url.deletingPathExtension().lastPathComponent, namespace: namespace)
        }
      }
    }
    guard Set(result.map(\.id)).count == result.count else { throw NotebookError.ambiguousRecord }
    return result.sorted {
      $0.memo.created == $1.memo.created ? $0.id < $1.id : $0.memo.created > $1.memo.created
    }
  }

  public func append(_ memo: Memo) throws {
    guard !memo.body.contains(DayDocument.modern) else { throw NotebookError.reservedSeparator }
    guard
      !memo.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !memo.attachments.isEmpty
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
      guard !document.blocks.compactMap(Memo.fromMarkdown).contains(where: { $0.id == memo.id })
      else { throw NotebookError.ambiguousRecord }
      let expected = document.blocks.compactMap(Memo.fromMarkdown).map(\.id) + [memo.id]
      document.blocks.append(memo.toMarkdown())
      try self.validateEncoding(document, expected: expected)
      try document.content.write(to: coordinated, atomically: true, encoding: .utf8)
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
      var document = DayDocument(try String(contentsOf: coordinated, encoding: .utf8))
      guard document.valid else { throw NotebookError.ambiguousRecord }
      let matches = document.blocks.indices.filter {
        Memo.fromMarkdown(document.blocks[$0])?.id == entry.memo.id
      }
      guard matches.count == 1, let index = matches.first else {
        throw NotebookError.ambiguousRecord
      }
      guard Memo.fromMarkdown(document.blocks[index]) == entry.memo else {
        throw NotebookError.conflict
      }
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

  private func fileURL(for entry: NotebookEntry) throws -> URL {
    guard Self.validDay(entry.day) else { throw NotebookError.invalidPath }
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
    let resolvedRoot = (allowedRoot ?? root).resolvingSymlinksInPath().standardizedFileURL.path
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
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
