import Testing
import Foundation
@testable import DayPage

/// Pure-logic coverage for the Doubao real-transcription test: the fuzzy
/// transcript matcher and the error-code → guidance mapping. Network probes
/// are exercised via the in-app test button, not unit tests.
@Suite("DoubaoConnectivityTester logic")
struct DoubaoConnectivityTesterTests {

    // MARK: Normalization

    @Test("normalize strips punctuation and whitespace")
    func normalizeStrips() {
        #expect(DoubaoConnectivityTester.normalize("你好，豆包。 今天天气不错！") == "你好豆包今天天气不错")
        #expect(DoubaoConnectivityTester.normalize("  ") == "")
    }

    // MARK: Fuzzy match

    @Test("exact transcript scores 1.0")
    func exactMatch() {
        #expect(DoubaoConnectivityTester.matchScore("你好豆包，今天天气不错。") == 1.0)
    }

    @Test("streaming word-drop still passes the 0.6 threshold")
    func wordDropPasses() {
        // Observed live: streaming fed faster than real time returned
        // 「你好，豆包不错。」 — every character appears in the expected
        // phrase, so the score stays 1.0 despite dropped words.
        #expect(DoubaoConnectivityTester.matchScore("你好，豆包不错。") >= 0.6)
    }

    @Test("unrelated transcript fails")
    func garbageFails() {
        #expect(DoubaoConnectivityTester.matchScore("购物清单牛奶鸡蛋面包") < 0.6)
    }

    @Test("empty transcript scores zero")
    func emptyScoresZero() {
        #expect(DoubaoConnectivityTester.matchScore("") == 0)
        #expect(DoubaoConnectivityTester.matchScore("。！？") == 0)
    }

    // MARK: Error guidance

    @Test("45000292 maps to the quota hint")
    func quotaHint() {
        let hint = DoubaoErrorGuide.hint(status: "45000292", message: "quota exceeded for types: concurrency", endpoint: .stream)
        #expect(hint.contains("45000292"))
    }

    @Test("resource-not-granted names the failing resource")
    func notGrantedHint() {
        let hint = DoubaoErrorGuide.hint(status: "403", message: "requested resource not granted", endpoint: .stream)
        #expect(hint.contains("sauc.duration"))

        let fileHint = DoubaoErrorGuide.hint(status: "403", message: "requested resource not granted", endpoint: .file)
        #expect(fileHint.contains("auc_turbo"))
    }

    @Test("unknown codes fall back to the raw detail")
    func unknownFallsBack() {
        let hint = DoubaoErrorGuide.hint(status: "99999999", message: "mystery", endpoint: .file)
        #expect(hint.contains("99999999") || hint.contains("mystery"))
    }

    // MARK: Sample PCM

    @Test("bundled sample yields non-trivial 16kHz PCM")
    func samplePCMParses() throws {
        // Bundle.main for a unit test host is the app bundle, so the wav
        // resource resolves. ~2.9s at 16kHz mono 16-bit ≈ 92KB.
        let pcm = try DoubaoConnectivityTester.samplePCM()
        #expect(pcm.count > 30_000)
        #expect(pcm.count % 2 == 0)
    }
}
