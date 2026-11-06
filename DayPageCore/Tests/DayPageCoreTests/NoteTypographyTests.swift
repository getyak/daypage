import XCTest
@testable import DayPageCore

final class NoteTypographyTests: XCTestCase {
  private func isolatedPreferences() throws -> (UserDefaults, String) {
    let name = "GET-418-typography-" + UUID().uuidString
    return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
  }

  func testExistingInstallationWithoutReadingPreferencesUsesSerifFifteenWithoutWriting() throws {
    let (defaults, name) = try isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("dark", forKey: "local.appearance")

    let typography = NoteTypography.load(from: defaults)

    XCTAssertEqual(typography.style, .serif)
    XCTAssertEqual(typography.size, 15)
    XCTAssertNil(defaults.object(forKey: NoteTypography.storageKey))
    XCTAssertEqual(defaults.string(forKey: "local.appearance"), "dark")
  }

  func testReadingChoiceSurvivesReopeningOnlyItsInjectedPreferences() throws {
    let (defaults, name) = try isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(Data([1, 2, 3]), forKey: "local.speech.channels.v1")
    NoteTypography.save(NoteTypography(style: .monospaced, size: 18.5), to: defaults)

    let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
    let loaded = NoteTypography.load(from: reopened)

    XCTAssertEqual(loaded.style, .monospaced)
    XCTAssertEqual(loaded.size, 18.5)
    XCTAssertEqual(reopened.data(forKey: "local.speech.channels.v1"), Data([1, 2, 3]))
  }

  func testPartialAndUnknownStylePreferencesPreserveTheIndependentValidSize() throws {
    let (defaults, name) = try isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: name) }
    for json in [#"{"size":19}"#, #"{"style":"future-font","size":19}"#,
                 #"{"style":false,"size":19}"#] {
      defaults.set(Data(json.utf8), forKey: NoteTypography.storageKey)
      let loaded = NoteTypography.load(from: defaults)
      XCTAssertEqual(loaded.style, .serif, json)
      XCTAssertEqual(loaded.size, 19, json)
    }
  }

  func testMissingAndInvalidSizePreserveTheIndependentValidStyle() throws {
    let (defaults, name) = try isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: name) }
    for json in [#"{"style":"rounded"}"#, #"{"style":"rounded","size":"large"}"#,
                 #"{"style":"rounded","size":true}"#, #"{"style":"rounded","size":null}"#] {
      defaults.set(Data(json.utf8), forKey: NoteTypography.storageKey)
      let loaded = NoteTypography.load(from: defaults)
      XCTAssertEqual(loaded.style, .rounded, json)
      XCTAssertEqual(loaded.size, 15, json)
    }
  }

  func testPreviouslySavedSupportedStylesAndOutOfRangeSizesRemainReadable() throws {
    let (defaults, name) = try isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: name) }
    let cases: [(String, NoteTypography.Style, Double)] = [
      (#"{"style":"serif","size":12}"#, .serif, 13),
      (#"{"style":"system","size":14}"#, .system, 14),
      (#"{"style":"rounded","size":24}"#, .rounded, 24),
      (#"{"style":"monospaced","size":1000}"#, .monospaced, 24)
    ]
    for (json, style, size) in cases {
      defaults.set(Data(json.utf8), forKey: NoteTypography.storageKey)
      let loaded = NoteTypography.load(from: defaults)
      XCTAssertEqual(loaded.style, style, json)
      XCTAssertEqual(loaded.size, size, json)
    }
  }

  func testMalformedOrOversizedPreferencePayloadFallsBackWithoutTouchingOtherKeys() throws {
    let (defaults, name) = try isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("light", forKey: "local.appearance")
    for payload in [Data("not json".utf8), Data("[]".utf8),
                    Data((#"{"style":"system","size":21,"unused":""# + String(repeating: "x", count: 8192) + #""}"#).utf8)] {
      defaults.set(payload, forKey: NoteTypography.storageKey)
      let loaded = NoteTypography.load(from: defaults)
      XCTAssertEqual(loaded.style, .serif)
      XCTAssertEqual(loaded.size, 15)
      XCTAssertEqual(defaults.string(forKey: "local.appearance"), "light")
    }
  }

  func testNonfiniteAndOutOfRangeInMemoryEditsCannotPersistAnUnusableFontSize() throws {
    let (defaults, name) = try isolatedPreferences()
    defer { defaults.removePersistentDomain(forName: name) }
    let cases: [(Double, Double)] = [(.nan, 15), (.infinity, 15), (-.infinity, 15),
                                    (-20, 13), (0, 13), (99, 24), (17.5, 17.5)]
    for (input, expected) in cases {
      var typography = NoteTypography(style: .system, size: input)
      XCTAssertEqual(typography.size, expected)
      typography.size = input
      XCTAssertEqual(typography.size, expected)
      NoteTypography.save(typography, to: defaults)
      let loaded = NoteTypography.load(from: defaults)
      XCTAssertEqual(loaded.style, .system)
      XCTAssertEqual(loaded.size, expected)
      XCTAssertTrue(loaded.size.isFinite)
    }
  }
}
