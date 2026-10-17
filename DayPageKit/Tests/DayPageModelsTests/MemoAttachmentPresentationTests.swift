// MemoAttachmentPresentationTests.swift — #884 follow-up read-only
// presentation of importer-generated media-only placeholder bodies.
//
// Synthetic fixtures only. No real labels, vaults, network or credentials.

import XCTest
@testable import DayPageModels

final class MemoAttachmentPresentationTests: XCTestCase {

    // MARK: - Fixtures (synthetic only)

    private func hex(_ char: Character = "a") -> String {
        String(repeating: String(char), count: 64)
    }

    private func attachment(kind: String, ext: String, hexChar: Character = "a",
                            file: String? = nil, transcript: String? = nil) -> Memo.Attachment {
        Memo.Attachment(
            file: file ?? "raw/assets/flomo/\(hex(hexChar)).\(ext)",
            kind: kind,
            transcript: transcript
        )
    }

    private func photo(ext: String = "png", hexChar: Character = "a",
                       file: String? = nil) -> Memo.Attachment {
        attachment(kind: "photo", ext: ext, hexChar: hexChar, file: file)
    }

    private func audio(ext: String = "m4a", hexChar: Character = "b",
                       file: String? = nil, transcript: String? = nil) -> Memo.Attachment {
        attachment(kind: "audio", ext: ext, hexChar: hexChar, file: file, transcript: transcript)
    }

    private func mov(hexChar: Character = "c", file: String? = nil) -> Memo.Attachment {
        attachment(kind: "file", ext: "mov", hexChar: hexChar, file: file)
    }

    private func line(_ label: String, name: String, file: String) -> String {
        "[\(label) attachment: \(name)](\(file))"
    }

    private func memo(_ body: String, _ attachments: [Memo.Attachment]) -> Memo {
        Memo(type: .mixed, created: Date(timeIntervalSince1970: 1_700_000_000),
             attachments: attachments, body: body)
    }

    // MARK: - Positives: exact generated media-only placeholder sets

    func test_photoOnlyGeneratedPlaceholder_presentsEmptyDisplayBody() {
        let att = photo()
        let body = line("Photo", name: "IMG_0001.png", file: att.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [att])), "")
    }

    func test_audioOnlyGeneratedPlaceholder_presentsEmptyDisplayBody_evenWithTranscript() {
        // The transcript is appended by the reading document separately; the
        // generated placeholder body itself still presents as empty.
        let att = audio(transcript: "讨论了咖啡烘焙机的进货渠道")
        let body = line("Audio", name: "voice note.m4a", file: att.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [att])), "")
    }

    func test_fileMovOnlyGeneratedPlaceholder_presentsEmptyDisplayBody() {
        let att = mov()
        let body = line("File", name: "clip.mov", file: att.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [att])), "")
    }

    func test_multiAttachmentOrderedSet_presentsEmptyDisplayBody() {
        let p = photo(hexChar: "a")
        let a = audio(hexChar: "b")
        let f = mov(hexChar: "c")
        let body = [
            line("Photo", name: "one.png", file: p.file),
            line("Audio", name: "two.m4a", file: a.file),
            line("File", name: "three.mov", file: f.file)
        ].joined(separator: "\n")
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [p, a, f])), "")
    }

    func test_unicodeFilenameWithSpacesParensBrackets_presentsEmptyDisplayBody() {
        let att = photo(ext: "jpeg", hexChar: "d")
        let body = line("Photo", name: "相册 照片 (2) [最终].jpeg", file: att.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [att])), "")

        let spaced = photo(ext: "jpg", hexChar: "e")
        let spacedBody = line("Photo", name: "old trip — day 1.jpg", file: spaced.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(spacedBody, [spaced])), "")
    }

    // MARK: - Negatives: prose, Markdown and code always preserve the body

    func test_realProsePlusGeneratedLines_preservesBody() {
        let att = photo()
        let body = "今天的记录\n\n" + line("Photo", name: "x.png", file: att.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [att])), body)
    }

    func test_normalMarkdownLinks_preserveBody() {
        let att = photo()
        // Ordinary prose link with the wrong target.
        let external = "[Photo attachment: x.png](https://example.com/x.png)"
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(external, [att])), external)

        // Ordinary link text that only looks like a placeholder name.
        let other = "[Photo attachment: x.png](raw/assets/flomo/\(hex("f")).png)"
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(other, [att])), other)

        // Plain Markdown without attachments at all.
        let prose = "[标题](https://example.com) 与 **加粗** 文本"
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(prose, [])), prose)
    }

    func test_codeFenceContainingPlaceholderLine_preservesBody() {
        let att = photo()
        let body = "```\n" + line("Photo", name: "x.png", file: att.file) + "\n```"
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [att])), body)

        let inline = "`" + line("Photo", name: "x.png", file: att.file) + "`"
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(inline, [att])), inline)
    }

    func test_surroundingRealTextOnPlaceholderLine_preservesBody() {
        let att = photo()
        let prefix = "附件在这里 " + line("Photo", name: "x.png", file: att.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(prefix, [att])), prefix)
        let suffix = line("Photo", name: "x.png", file: att.file) + " 就是这张"
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(suffix, [att])), suffix)
    }

    // MARK: - Negatives: wrong / missing / extra / duplicate / order / kind

    func test_wrongLabelPreservesBody() {
        let att = photo()
        let body = line("Audio", name: "x.png", file: att.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [att])), body)
    }

    func test_missingAndExtraAndDuplicateLinesPreserveBody() {
        let p = photo(hexChar: "a")
        let a = audio(hexChar: "b")
        let photoLine = line("Photo", name: "x.png", file: p.file)
        let audioLine = line("Audio", name: "y.m4a", file: a.file)

        // Missing line: 2 attachments, only one line.
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(photoLine, [p, a])), photoLine)
        // Extra line: 1 attachment, two lines.
        let extra = photoLine + "\n" + audioLine
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(extra, [p])), extra)
        // Duplicate line: 1 attachment, the same line twice.
        let duplicate = photoLine + "\n" + photoLine
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(duplicate, [p])), duplicate)
    }

    func test_wrongOrderAndWrongKindPreserveBody() {
        let p = photo(hexChar: "a")
        let a = audio(hexChar: "b")
        let photoLine = line("Photo", name: "x.png", file: p.file)
        let audioLine = line("Audio", name: "y.m4a", file: a.file)

        // Swapped order.
        let swapped = audioLine + "\n" + photoLine
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(swapped, [p, a])), swapped)

        // Kind outside photo/audio/file can never be generated.
        let custom = attachment(kind: "screenshot", ext: "png", hexChar: "a")
        let customBody = line("Photo", name: "x.png", file: custom.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(customBody, [custom])), customBody)

        // Kind/extension mismatch: a photo is never a .mov and audio never .png.
        let wrongPhoto = photo(ext: "png", hexChar: "a", file: "raw/assets/flomo/\(hex("a")).mov")
        let wrongPhotoBody = line("Photo", name: "x.mov", file: wrongPhoto.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(wrongPhotoBody, [wrongPhoto])), wrongPhotoBody)

        let wrongAudio = audio(ext: "m4a", hexChar: "b", file: "raw/assets/flomo/\(hex("b")).png")
        let wrongAudioBody = line("Audio", name: "y.png", file: wrongAudio.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(wrongAudioBody, [wrongAudio])), wrongAudioBody)
    }

    // MARK: - Negatives: unsafe / non-canonical references

    func test_unsafeOrNonCanonicalFileReferencesPreserveBody() {
        let names: [(String, String)] = [
            ("traversal", "../assets/flomo/\(hex()).png"),
            ("absolute", "/var/tmp/\(hex()).png"),
            ("remote", "https://example.com/\(hex()).png"),
            ("uppercase hex", "raw/assets/flomo/\(hex("A")).png"),
            ("short hex", "raw/assets/flomo/\(String(repeating: "a", count: 63)).png"),
            ("query alias", "raw/assets/flomo/\(hex()).png?x=1"),
            ("percent-encoded alias", "raw/assets/flomo/%61.png"),
            ("extra segment", "raw/assets/flomo/sub/\(hex()).png"),
            ("missing prefix", "raw/assets/\(hex()).png"),
            ("unsupported extension", "raw/assets/flomo/\(hex()).heic")
        ]
        for (label, file) in names {
            let att = photo(file: file)
            let body = line("Photo", name: "x.png", file: file)
            XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [att])), body,
                           "must preserve body for \(label) reference")
        }
    }

    func test_lineLinkAliasesAndEmptyFilenamePreserveBody() {
        let att = photo()
        // The line suffix must be the EXACT stored file — alias spellings fail.
        let aliased = line("Photo", name: "x.png", file: "raw/assets/flomo/\(hex()).png?raw=1")
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(aliased, [att])), aliased)

        // An empty original filename is not a generated line.
        let emptyName = line("Photo", name: "", file: att.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(emptyName, [att])), emptyName)

        // A path-shaped "filename" is not a generated line.
        let pathName = line("Photo", name: "a/b.png", file: att.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(pathName, [att])), pathName)
    }

    func test_noAttachmentsPlaceholderLookingBodyAndEmptyBodyPreserved() {
        let att = photo()
        let body = line("Photo", name: "x.png", file: att.file)
        // Body looks generated but the memo has no attachments: not generated.
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [])), body)

        // Body empty with attachments is not the generated set either.
        let empty = memo("", [att])
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: empty), "")
        XCTAssertEqual(empty.body, "")

        // Whitespace-trimmed match is still the exact generated set.
        let padded = memo("\n" + body + "\n", [att])
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: padded), "")
    }

    // MARK: - Raw body and transcript boundaries

    func test_rawBodySurvivesMarkdownRoundTrip_andPresentationIsPure() throws {
        let att = photo()
        let body = line("Photo", name: "照片 (1).png", file: att.file)
        let original = memo(body, [att])
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: original), "")

        let block = original.toMarkdown()
        let decoded = try XCTUnwrap(Memo.fromMarkdown(block), "raw round-trip must parse")
        XCTAssertEqual(decoded.body, body, "raw body must be untouched")
        XCTAssertEqual(decoded.attachments.map(\.file), [att.file])
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: decoded), "")

        // A prose body is likewise untouched and presents as itself.
        let prose = memo("真实正文 [Photo attachment: x.png](\(att.file))", [att])
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: prose), prose.body)
        let decodedProse = try XCTUnwrap(Memo.fromMarkdown(prose.toMarkdown()))
        XCTAssertEqual(decodedProse.body, prose.body)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: decodedProse), decodedProse.body)
    }

    func test_audioTranscriptNeverAltersDisplayBody() {
        let att = audio(transcript: "语音转写内容")
        // Generated placeholder + transcript: still the empty presentation;
        // the transcript is source-appended elsewhere, not by displayBody.
        let generated = memo(line("Audio", name: "v.m4a", file: att.file), [att])
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: generated), "")

        // A body that happens to equal the transcript is ordinary prose.
        let prose = memo("语音转写内容", [att])
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: prose), prose.body)

        // Transcript content mixed with placeholders never matches.
        let mixed = memo(line("Audio", name: "v.m4a", file: att.file) + "\n语音转写内容", [att])
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: mixed), mixed.body)
    }

    // MARK: - Production sync-mapped attachment paths (v2 pull)

    private func syncPath(sha: Character, name: String) -> String {
        "raw/assets/sync/\(hex(sha))-\(name)"
    }

    private func flomoTarget(sha: Character, ext: String) -> String {
        "raw/assets/flomo/\(hex(sha)).\(ext)"
    }

    /// A downloaded v2 attachment lives at the deterministic
    /// `raw/assets/sync/<SHA>-<String(name.prefix(255))>` path while the body
    /// keeps the original flomo link; that exact correspondence must present
    /// empty — for photo, audio and MOV file attachments alike.
    func test_productionSyncMappedPaths_presentEmptyDisplayBody_photoAudioMov() {
        let photoAtt = photo(ext: "png", hexChar: "a", file: syncPath(sha: "a", name: "IMG 1.png"))
        let photoBody = line("Photo", name: "IMG 1.png", file: flomoTarget(sha: "a", ext: "png"))
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(photoBody, [photoAtt])), "")

        let audioAtt = audio(ext: "m4a", hexChar: "b", file: syncPath(sha: "b", name: "语音 笔记.m4a"))
        let audioBody = line("Audio", name: "语音 笔记.m4a", file: flomoTarget(sha: "b", ext: "m4a"))
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(audioBody, [audioAtt])), "")

        let fileAtt = mov(hexChar: "c", file: syncPath(sha: "c", name: "clip (final).mov"))
        let fileBody = line("File", name: "clip (final).mov", file: flomoTarget(sha: "c", ext: "mov"))
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(fileBody, [fileAtt])), "")

        // Mixed set: original flomo path and sync-mapped path in one memo.
        let mixedMemo = memo(
            [photoBody, audioBody, fileBody].joined(separator: "\n"),
            [photoAtt, audioAtt, fileAtt])
        let bodySnapshot = mixedMemo.body
        let filesSnapshot = mixedMemo.attachments.map(\.file)
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: mixedMemo), "")
        // Raw body and attachment paths are untouched by presentation.
        XCTAssertEqual(mixedMemo.body, bodySnapshot)
        XCTAssertEqual(mixedMemo.attachments.map(\.file), filesSnapshot)
    }

    /// Unicode, combining and emoji basenames correspond byte-for-byte.
    func test_unicodeCombiningEmojiBasename_syncMappingMatchesBytewise() {
        let name = "café 追加😀 (1).png"
        let att = photo(ext: "png", hexChar: "d", file: syncPath(sha: "d", name: name))
        let body = line("Photo", name: name, file: flomoTarget(sha: "d", ext: "png"))
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [att])), "")

        let combining = "cafe\u{301} 追加😀 (1).png"
        let combiningAtt = photo(ext: "png", hexChar: "d", file: syncPath(sha: "d", name: combining))
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [combiningAtt])), body,
                       "byte-distinct canonically-equivalent filenames must not correspond")
    }

    /// The production sanitizer truncates at 255 Swift Characters — the
    /// correspondence is exactly `String(name.prefix(255))`, never more/less.
    func test_filenameTruncationBoundary_255Characters() {
        let name255 = String(repeating: "n", count: 251) + ".png"
        XCTAssertEqual(name255.count, 255)
        let att255 = photo(ext: "png", hexChar: "e", file: syncPath(sha: "e", name: name255))
        let body255 = line("Photo", name: name255, file: flomoTarget(sha: "e", ext: "png"))
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body255, [att255])), "")

        let name256 = String(repeating: "n", count: 252) + ".png"
        XCTAssertEqual(name256.count, 256)
        let truncated = String(name256.prefix(255))
        let attTruncated = photo(ext: "png", hexChar: "e", file: syncPath(sha: "e", name: truncated))
        let body256 = line("Photo", name: name256, file: flomoTarget(sha: "e", ext: "png"))
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body256, [attTruncated])), "")

        // Full (untruncated) suffix is NOT the production path.
        let attFull = photo(ext: "png", hexChar: "e", file: syncPath(sha: "e", name: name256))
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body256, [attFull])), body256)
    }

    /// PUBLIC regression for the ASCII hash shape: the target hash must be
    /// exactly 64 ASCII lowercase-hex UTF-8 BYTES. Grapheme look-alikes such
    /// as 64 repeats of `a`+U+FE0F or `0`+U+FE0F are not hex and must
    /// preserve the body even when the attachment path is byte-identical.
    func test_variationSelectorGraphemeHashTargets_areNotCanonicalHex() {
        for grapheme in ["a\u{FE0F}", "0\u{FE0F}"] {
            let fakeHash = String(repeating: grapheme, count: 64)
            let target = "raw/assets/flomo/\(fakeHash).png"
            let att = photo(ext: "png", hexChar: "a", file: target)
            let body = line("Photo", name: "x.png", file: target)
            XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [att])), body,
                           "grapheme-hex target \(grapheme.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined()) must preserve the body")
        }
    }

    /// Sync-mapped correspondence rejects wrong SHA/name/kind, loose hash
    /// prefixes, arbitrary suffixes, order/extra-line drift and prose.
    func test_syncMappedCorrespondenceRejectsWrongSHANameKindOrderAndProse() {
        let name = "photo.png"
        let body = line("Photo", name: name, file: flomoTarget(sha: "a", ext: "png"))

        let wrongSHA = photo(ext: "png", hexChar: "a", file: syncPath(sha: "f", name: name))
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [wrongSHA])), body)

        let wrongName = photo(ext: "png", hexChar: "a", file: syncPath(sha: "a", name: "other.png"))
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [wrongName])), body)

        let loosePrefix = photo(ext: "png", hexChar: "a", file: "raw/assets/sync/aaaa-photo.png")
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [loosePrefix])), body)

        let wrongKind = attachment(kind: "screenshot", ext: "png", hexChar: "a",
                                   file: syncPath(sha: "a", name: name))
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(body, [wrongKind])), body)

        // Order drift with sync-mapped paths.
        let secondBody = line("Photo", name: "second.png", file: flomoTarget(sha: "b", ext: "png"))
        let firstAtt = photo(ext: "png", hexChar: "a", file: syncPath(sha: "a", name: name))
        let secondAtt = photo(ext: "png", hexChar: "b", file: syncPath(sha: "b", name: "second.png"))
        let swapped = secondBody + "\n" + body
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(swapped, [firstAtt, secondAtt])), swapped)

        // Extra line and prose never match.
        let extra = body + "\n" + secondBody
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(extra, [firstAtt])), extra)
        let prose = "真实正文 " + body
        XCTAssertEqual(MemoAttachmentPresentation.displayBody(for: memo(prose, [firstAtt])), prose)
    }

    /// A filename containing Unicode controls is uncertain and must never
    /// suppress original text, including the actual cloud path correspondence.
    func test_nonASCIIControlFilenames_preserveBody_forOriginalAndCloudPaths() {
        for control in ["\u{0085}", "\u{009F}", "\u{200B}"] {
            let name = "before\(control)after.png"
            let target = flomoTarget(sha: "a", ext: "png")
            let body = line("Photo", name: name, file: target)
            for currentFile in [target, syncPath(sha: "a", name: name)] {
                let att = photo(file: currentFile)
                XCTAssertEqual(
                    MemoAttachmentPresentation.displayBody(for: memo(body, [att])), body,
                    "Uncertain control-bearing filename must preserve the body")
            }
        }
    }

}
