import XCTest
@testable import DayPageCore

final class NotebookPathTests: XCTestCase {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("daypage-path-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func spellings(_ url: URL) -> (URL, URL) {
    let path = url.path
    if path.hasPrefix("/private/var/") || path.hasPrefix("/private/tmp/") {
      return (URL(fileURLWithPath: String(path.dropFirst("/private".count))), url)
    }
    if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") {
      return (url, URL(fileURLWithPath: "/private" + path))
    }
    return (url, url)
  }
  private func creation(_ body: String) async throws -> NoteActionProposal {
    let args = try JSONSerialization.data(withJSONObject: ["body": body])
    let result = try await NoteToolExecutor.execute(name: "notes_create", arguments: String(decoding: args, as: UTF8.self), context: .init(entries: []))
    return try XCTUnwrap(result.proposals.first)
  }

  func testFreshNestedRootSupportsAppendAndProposalBeforeAnyDirectoryExists() async throws {
    let parent = try fixture(), (_, canonical) = spellings(parent)
    let appendRoot = canonical.appendingPathComponent("new-parent/append-root")
    let store = NotebookStore(root: appendRoot)
    let before = NotebookPath.canonicalPath(appendRoot)
    try await store.append(Memo(body: "Fresh nested capture"))
    XCTAssertEqual(NotebookPath.canonicalPath(appendRoot), before)
    let entries = try await store.entries()
    XCTAssertEqual(entries.first?.memo.body, "Fresh nested capture")
    let proposalRoot = canonical.appendingPathComponent("new-parent/proposal-root")
    let actionStore = NotebookStore(root: proposalRoot)
    let proposal = try await creation("Fresh nested review")
    try await actionStore.saveProposal(proposal)
    _ = try await actionStore.apply(proposal, allowedCardRefs: [])
    let created = try await actionStore.entries()
    XCTAssertEqual(created.first?.memo.body, "Fresh nested review")
  }

  func testAliasAndCanonicalRootsShareRecordProvenanceAndPreserveImportedBytes() async throws {
    let parent = try fixture(), (aliasParent, canonicalParent) = spellings(parent)
    let canonical = canonicalParent.appendingPathComponent("shared-root")
    let first = NotebookStore(root: canonical)
    try await first.append(Memo(body: "Original local body"))
    let initial = try await first.entries()
    let local = try XCTUnwrap(initial.first)
    let reopened = NotebookStore(root: aliasParent.appendingPathComponent("shared-root"))
    try await reopened.update(local, body: "Updated through alias")
    let namespace = UUID().uuidString
    let raw = canonical.appendingPathComponent("imports/\(namespace)/raw")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    let importedMemo = Memo(body: "Imported body #kept")
    let importedFile = raw.appendingPathComponent("\(local.day).md")
    let original = importedMemo.toMarkdown().replacingOccurrences(of: "type: text", with: "external: preserve\ntype: text")
    try original.write(to: importedFile, atomically: true, encoding: .utf8)
    let all = try await first.entries()
    let imported = try XCTUnwrap(all.first { $0.namespace == namespace })
    try await reopened.update(imported, body: "Changed import #kept")
    XCTAssertTrue(try String(contentsOf: importedFile, encoding: .utf8).contains("external: preserve"))
    let refreshed = try await first.entries()
    let saved = try XCTUnwrap(refreshed.first { $0.id == imported.id })
    let receipt = try await first.trash(saved)
    try await reopened.restore(receipt)
    XCTAssertTrue(try String(contentsOf: importedFile, encoding: .utf8).contains("Changed import #kept"))
    do { try await first.importVault(from: aliasParent.appendingPathComponent("shared-root")); XCTFail("Aliased self-import must fail") } catch NotebookError.invalidVault { }
  }

  func testInternalAndDanglingRawLinksAndLinkedRootAreRejected() async throws {
    let parent = try fixture()
    for dangling in [false, true] {
      let root = parent.appendingPathComponent(dangling ? "dangling" : "internal")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let destination = root.appendingPathComponent("real-raw")
      if !dangling { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
      try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("raw"), withDestinationURL: destination)
      let store = NotebookStore(root: root)
      do { try await store.append(Memo(body: "Must not follow link")); XCTFail("Raw links must fail") } catch NotebookError.invalidPath { }
    }
    let actual = parent.appendingPathComponent("actual-root")
    try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
    let link = parent.appendingPathComponent("linked-root")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
    let linkedStore = NotebookStore(root: link)
    let proposal = try await creation("Must reject linked root")
    do { try await linkedStore.saveProposal(proposal); XCTFail("Root links must fail") } catch NotebookError.invalidPath { }
    XCTAssertFalse(FileManager.default.fileExists(atPath: actual.appendingPathComponent(".daypage").path))
  }

  func testPrefixSiblingCannotSupplyAnEntryOrReceiptToThisNotebook() async throws {
    let parent = try fixture()
    let root = parent.appendingPathComponent("vault"), sibling = parent.appendingPathComponent("vault-extra")
    let store = NotebookStore(root: root), other = NotebookStore(root: sibling)
    try await other.append(Memo(body: "Sibling original bytes"))
    let entries = try await other.entries(), entry = try XCTUnwrap(entries.first)
    do { try await store.update(entry, body: "Must not overwrite"); XCTFail("Sibling entry denied") } catch NotebookError.invalidPath { }
    let receipt = try await other.trash(entry)
    do { try await store.restore(receipt); XCTFail("Sibling receipt denied") } catch NotebookError.invalidPath { }
    let files = try FileManager.default.contentsOfDirectory(atPath: sibling.appendingPathComponent("raw").path)
    XCTAssertEqual(files.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("raw").path))
  }

  func testMissingAncestorTraversalIsNormalizedOutsideTheNotebookPrefix() throws {
    let parent = try fixture(), (_, canonicalParent) = spellings(parent)
    let root = canonicalParent.appendingPathComponent("vault")
    let escaped = URL(fileURLWithPath: root.path + "/missing/../../outside/note.md")
    let actual = NotebookPath.canonicalPath(escaped)
    let expected = NotebookPath.canonicalPath(canonicalParent.appendingPathComponent("outside/note.md"))
    XCTAssertEqual(actual, expected)
    XCTAssertFalse(actual.hasPrefix(NotebookPath.canonicalPath(root) + "/"))
    XCTAssertFalse(actual.components(separatedBy: "/").contains(".."))
    let normalized = NotebookPath.canonicalPath(URL(fileURLWithPath: root.path + "/missing/.././raw/note.md"))
    XCTAssertEqual(normalized, NotebookPath.canonicalPath(root.appendingPathComponent("raw/note.md")))
    XCTAssertFalse(normalized.components(separatedBy: "/").contains("."))
  }

  func testFreshAssetAndImportedNamespaceResolveAcrossCanonicalAliasesWithoutChangingOriginals() async throws {
    let parent = try fixture(), (aliasParent, canonicalParent) = spellings(parent)
    let source = canonicalParent.appendingPathComponent("fresh-source")
    let sourceStore = NotebookStore(root: source)
    let payload = Data("A synthetic text attachment".utf8)
    try await sourceStore.append(Memo(body: "A memo with an attachment"), assets: [
      NotebookAssetInput(data: payload, fileExtension: "txt", kind: "file")
    ])
    let entries = try await sourceStore.entries(), entry = try XCTUnwrap(entries.first)
    let attachment = try XCTUnwrap(entry.memo.attachments.first)
    let asset = try await sourceStore.assetURL(attachment.file, for: entry)
    XCTAssertEqual(try Data(contentsOf: asset), payload)
    let aliasedStore = NotebookStore(root: aliasParent.appendingPathComponent("fresh-source"))
    let aliasedAsset = try await aliasedStore.assetURL(attachment.file, for: entry)
    XCTAssertEqual(try Data(contentsOf: aliasedAsset), payload)
    let originalFile = source.appendingPathComponent("raw/\(entry.day).md")
    let originalMarkdown = try Data(contentsOf: originalFile)
    let destination = canonicalParent.appendingPathComponent("fresh-destination")
    let destinationStore = NotebookStore(root: destination)
    try await destinationStore.importVault(from: aliasParent.appendingPathComponent("fresh-source"))
    let importedEntries = try await destinationStore.entries()
    let imported = try XCTUnwrap(importedEntries.first)
    XCTAssertFalse(imported.namespace.isEmpty)
    let importedAttachment = try XCTUnwrap(imported.memo.attachments.first)
    let importedAsset = try await destinationStore.assetURL(importedAttachment.file, for: imported)
    XCTAssertEqual(try Data(contentsOf: importedAsset), payload)
    let importedFile = destination.appendingPathComponent("imports/\(imported.namespace)/raw/\(entry.day).md")
    XCTAssertEqual(try Data(contentsOf: importedFile), originalMarkdown)
    XCTAssertEqual(try Data(contentsOf: originalFile), originalMarkdown)
    XCTAssertEqual(try Data(contentsOf: asset), payload)
    for path in ["/tmp/outside.txt", "../outside.txt", "raw/assets/../../outside.txt"] {
      do { _ = try await destinationStore.assetURL(path, for: imported); XCTFail("Unsafe asset path denied") } catch NotebookError.invalidPath { }
    }
    for dangling in [false, true] {
      let filename = dangling ? "dangling.txt" : "internal-link.txt"
      let link = importedAsset.deletingLastPathComponent().appendingPathComponent(filename)
      let target = dangling ? importedAsset.deletingLastPathComponent().appendingPathComponent("missing-target.txt") : importedAsset
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      do { _ = try await destinationStore.assetURL("raw/assets/" + filename, for: imported); XCTFail("Asset links must be denied") } catch NotebookError.invalidPath { }
    }
    XCTAssertEqual(try Data(contentsOf: importedAsset), payload)
    XCTAssertEqual(try Data(contentsOf: asset), payload)
  }

  func testImportRejectsLinkedRootAndImportsBeforeTouchingSiblingOrSourceBytes() async throws {
    let parent = try fixture()
    let source = parent.appendingPathComponent("import-source")
    let sourceStore = NotebookStore(root: source)
    try await sourceStore.append(Memo(body: "Source Markdown must remain unchanged"))
    let sourceEntries = try await sourceStore.entries(), sourceEntry = try XCTUnwrap(sourceEntries.first)
    let sourceFile = source.appendingPathComponent("raw/\(sourceEntry.day).md")
    let sourceBytes = try Data(contentsOf: sourceFile)
    for linkedRoot in [true, false] {
      let label = linkedRoot ? "root" : "imports"
      let sibling = parent.appendingPathComponent("protected-sibling-\(label)")
      try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
      let sentinel = sibling.appendingPathComponent("sentinel.txt"), bytes = Data("Protected sibling \(label)".utf8)
      try bytes.write(to: sentinel)
      let root = parent.appendingPathComponent("linked-\(label)-vault")
      if linkedRoot {
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: sibling)
      } else {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("imports"), withDestinationURL: sibling)
      }
      let beforeSibling = try FileManager.default.contentsOfDirectory(atPath: sibling.path).sorted()
      let beforeRoot = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
      let store = NotebookStore(root: root)
      do { try await store.importVault(from: source); XCTFail("Linked \(label) must not redirect import") } catch NotebookError.invalidPath { }
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sibling.path).sorted(), beforeSibling)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), beforeRoot)
      XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
      XCTAssertEqual(try Data(contentsOf: sourceFile), sourceBytes)
    }
  }
}
