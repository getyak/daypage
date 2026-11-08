import XCTest
@testable import DayPageCore

final class ExchangeTimestampTests: XCTestCase {
  private func fixture(created: String = "2026-11-07T02:03:04.123Z", pinned: String? = nil) throws -> (URL, NotebookStore, Data) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("exchange-time-\(UUID())")
    let raw = "---\nid: 11111111-2222-4333-8444-555555555555\ntype: text\ncreated: \(created)\n"
      + (pinned.map { "pinned_at: \($0)\n" } ?? "") + "---\n\nSynthetic timestamp fixture"
    try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
    let bytes = Data(raw.utf8); try bytes.write(to: root.appendingPathComponent("raw/2026-11-07.md"))
    return (root, NotebookStore(root: root), bytes)
  }
  private func whole() throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-07T02:03:04Z")) }

  func testSharedCrossLanguageGoldenTimestampInputsHaveIndependentExpectedValues() throws {
    struct Raw: Decodable { let value: String; let projected: String? }
    struct Typed: Decodable { let value: String; let accepted: Bool; let projected: String? }
    struct Review: Decodable { let referenceSeconds: Double; let projected: String }
    struct Fixture: Decodable { let version: Int; let raw: [Raw]; let typed: [Typed]; let reviewDates: [Review] }
    let path = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
      .appendingPathComponent("exchange-timestamp-projection-v1.json")
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let fixture = try decoder.decode(Fixture.self, from: Data(contentsOf: path))
    XCTAssertEqual(fixture.version, 1)
    for example in fixture.raw { XCTAssertEqual(ExchangeTimestamp.projectRaw(example.value), example.projected, example.value) }
    for example in fixture.typed {
      let instant = ExchangeTimestamp.date(example.value)
      XCTAssertEqual(instant != nil, example.accepted, example.value)
      if let instant { XCTAssertEqual(ExchangeTimestamp.string(instant), example.projected, example.value) }
    }
    for example in fixture.reviewDates {
      XCTAssertEqual(ExchangeTimestamp.string(Date(timeIntervalSinceReferenceDate: example.referenceSeconds)), example.projected)
    }
  }

  func testRealRawMemoMillisecondsAndPinnedTimeRoundTripWithoutChangingRawBytes() async throws {
    let (root, store, original) = try fixture(pinned: "2026-11-07T03:03:04.789Z")
    defer { try? FileManager.default.removeItem(at: root) }
    let exported = try await store.exchangeSnapshot(), note = try XCTUnwrap(exported.records.notes.first)
    XCTAssertEqual(note.createdAt, "2026-11-07T02:03:04.123Z")
    XCTAssertEqual(note.pinnedAt, "2026-11-07T03:03:04.789Z")
    XCTAssertEqual(exported.files["raw/2026-11-07.md"], original)
    try NotebookStore.validateExchangeProjection(exported)
  }

  func testDecimalSourceProjectionRoundsCarriesOffsetsAndBothSidesOfEpochExactly() {
    let examples = [
      "2026-11-07T02:03:04Z": "2026-11-07T02:03:04Z",
      "2026-11-07t02:03:04.123z": "2026-11-07T02:03:04.123Z",
      "2026-11-07T10:03:04.1234+08:00": "2026-11-07T02:03:04.123Z",
      "2026-11-07T10:03:04.1235+08:00": "2026-11-07T02:03:04.124Z",
      "2026-11-07T02:03:04.9995Z": "2026-11-07T02:03:05Z",
      "2026-11-07T23:59:59.9995Z": "2026-11-08T00:00:00Z",
      "1969-12-31T23:59:59.9995Z": "1969-12-31T23:59:59.999Z",
      "1970-01-01T00:00:00.0005Z": "1970-01-01T00:00:00.001Z",
    ]
    for (source, expected) in examples { XCTAssertEqual(ExchangeTimestamp.projectRaw(source), expected, source) }
    XCTAssertNil(ExchangeTimestamp.projectRaw("2026-11-07T02:03:04+24:00"))
    XCTAssertNil(ExchangeTimestamp.projectRaw("2026-11-07T02:03:04+08:60"))
    XCTAssertNil(ExchangeTimestamp.projectRaw("2026-02-30T02:03:04Z"))
    XCTAssertNil(ExchangeTimestamp.projectRaw("2026-11-07T02:03:60Z"))
    XCTAssertEqual(ExchangeTimestamp.projectRaw("2026-11-07T23:59:04+23:59"), "2026-11-07T00:00:04Z")
  }

  func testDateClockProjectionKeepsWholeSecondsAndMemoMillisecondsIncludingCarry() throws {
    let base = try whole()
    XCTAssertEqual(ExchangeTimestamp.string(base), "2026-11-07T02:03:04Z")
    XCTAssertEqual(ExchangeTimestamp.string(base.addingTimeInterval(0.123)), "2026-11-07T02:03:04.123Z")
    XCTAssertEqual(ExchangeTimestamp.string(base.addingTimeInterval(0.9996)), "2026-11-07T02:03:05Z")
  }

  func testLeadingWhitespaceUsesTheMemoCodecButRawBytesAndRevisionStayExact() async throws {
    let (root, store, original) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let wrapped = Data("\n \t".utf8) + original + Data("\n\t ".utf8)
    try wrapped.write(to: root.appendingPathComponent("raw/2026-11-07.md"))
    let exported = try await store.exchangeSnapshot()
    XCTAssertEqual(exported.files["raw/2026-11-07.md"], wrapped)
    XCTAssertEqual(exported.records.notes.first?.revision, ReplicaDigest.hash(wrapped))
    XCTAssertEqual(exported.records.notes.first?.createdAt, "2026-11-07T02:03:04.123Z")
  }

  func testLegacyBodyWithFakeMemoAndNonMemoTailFallsBackBeforeTimestampAdmission() async throws {
    let (root, store, original) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let fake = "---\nid: 22222222-2222-4222-8222-222222222222\ntype: text\n---\n\nQuoted example without a timestamp"
    let bytes = original + Data(("\n\n---\n\n" + fake + "\n\n---\n\nNot a Memo record").utf8)
    try bytes.write(to: root.appendingPathComponent("raw/2026-11-07.md"))
    let ordinary = try await store.entries(), selected = try await store.exchangeEntries()
    XCTAssertEqual(ordinary.count, 1); XCTAssertEqual(selected, ordinary)
    let exported = try await store.exchangeSnapshot()
    XCTAssertEqual(exported.files["raw/2026-11-07.md"], bytes)
    XCTAssertEqual(exported.records.notes.count, 1)
    XCTAssertTrue(exported.records.notes[0].body.contains(fake))
  }

  func testReviewMetadataRetainsItsFullJSONDateWhileTypedClockIsExplicitlyMilliseconds() async throws {
    let (root, store, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = try await store.entries(), base = try whole()
    let period = try ReviewPeriod(kind: .day, anchor: base, timeZone: .gmt)
    let source = try ManualReviewSnapshot.make(period: period, entries: entries, selectedIDs: Set(entries.map(\.id)))
    let precise = Date(timeIntervalSinceReferenceDate: base.timeIntervalSinceReferenceDate + 0.123456)
    let page = ManualReviewPage(id: UUID(), created: precise, snapshot: source, body: "Synthetic review clock")
    let bytes = try page.encoded(), path = "wiki/manual-reviews/\(page.id.uuidString).md"
    try FileManager.default.createDirectory(at: root.appendingPathComponent("wiki/manual-reviews"), withIntermediateDirectories: true)
    try bytes.write(to: root.appendingPathComponent(path))
    let exported = try await store.exchangeSnapshot(), projected = try XCTUnwrap(exported.records.reviews.first)
    XCTAssertEqual(projected.createdAt, "2026-11-07T02:03:04.123Z")
    XCTAssertEqual(exported.files[path], bytes)
    let reopened = try ManualReviewPage.decode(XCTUnwrap(exported.files[path]))
    XCTAssertEqual(reopened.created, precise)
    XCTAssertNotEqual(reopened.created, ExchangeTimestamp.date(projected.createdAt))
    XCTAssertEqual(try reopened.encoded(), bytes)
    try exported.validated()
  }

  func testTypedTimeCannotUseDateParserClippingToHideContradictorySubmillisecondDigits() {
    XCTAssertNil(ExchangeTimestamp.date("2026-11-07T02:03:04.1234Z"))
    XCTAssertNil(ExchangeTimestamp.date("2026-11-07T02:03:04.0000001Z"))
    XCTAssertEqual(ExchangeTimestamp.date("2026-11-07T02:03:04.123000Z"), ExchangeTimestamp.date("2026-11-07T02:03:04.123Z"))
  }

  func testValidFileHashesDoNotAuthorizeContradictoryTypedCreationTime() async throws {
    let (root, store, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try await store.exchangeSnapshot()
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReplicaDigest.encode(original.records)) as? [String: Any])
    var notes = try XCTUnwrap(object["notes"] as? [[String: Any]])
    notes[0]["created_at"] = "2026-11-07T02:03:04.1234Z"; object["notes"] = notes
    let data = try JSONSerialization.data(withJSONObject: object), records = try ExchangeRecords.decode(data)
    var files = original.files; files["records.json"] = data
    let listing = try files.map { ExchangeFile(path: $0.key, bytes: $0.value.count,
      sha256: ReplicaDigest.hash($0.value), kind: try ExchangePath.kind($0.key)) }
    let changed = VaultExchangeSnapshot(manifest: VaultExchangeManifest(notes: records.notes.count, reviews: records.reviews.count, files: listing), records: records, files: files)
    XCTAssertThrowsError(try changed.validated())
  }

  func testExchangeRefusesToInventNowForMalformedRawTimeWhileOrdinaryReadPolicyIsUnchanged() async throws {
    let (root, store, _) = try fixture(created: "not-a-time")
    defer { try? FileManager.default.removeItem(at: root) }
    let ordinary = try await store.entries(); XCTAssertEqual(ordinary.count, 1)
    let earlier = try XCTUnwrap(ISO8601DateFormatter().date(from: "2001-01-01T00:00:00Z"))
    let period = try ReviewPeriod(kind: .day, anchor: earlier, timeZone: .gmt)
    do { _ = try await store.exchangeEntries(period: period); XCTFail("Date() cannot decide whether malformed source time belongs to the chosen period") }
    catch VaultExchangeError.invalid { }
    do { _ = try await store.exchangeSnapshot(); XCTFail("An invented current time is not canonical source parity") }
    catch VaultExchangeError.invalid { }
  }

  func testUnrepresentableReviewClockIsRejectedInsteadOfAnEmptyWireTimestamp() async throws {
    let (root, store, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = try await store.entries(), base = try whole()
    let period = try ReviewPeriod(kind: .day, anchor: base, timeZone: .gmt)
    let source = try ManualReviewSnapshot.make(period: period, entries: entries, selectedIDs: Set(entries.map(\.id)))
    let page = ManualReviewPage(id: UUID(), created: Date(timeIntervalSinceReferenceDate: 1e100), snapshot: source, body: "Synthetic unsupported clock")
    let folder = root.appendingPathComponent("wiki/manual-reviews")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try page.encoded().write(to: folder.appendingPathComponent(page.id.uuidString + ".md"))
    do { _ = try await store.exchangeSnapshot(); XCTFail() } catch VaultExchangeError.invalid { }
  }
}
