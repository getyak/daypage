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
}
