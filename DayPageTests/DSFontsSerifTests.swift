import XCTest
import SwiftUI
@testable import DayPage

final class DSFontsSerifTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DSFonts.registerAll()
    }

    // MARK: - Helpers

    /// Asserts `psName` is a real face UIKit can resolve in *this* process
    /// after synchronous registration, and returns it. A missing face is a
    /// hard failure — never a skip.
    private func requireFace(_ psName: String, size: CGFloat = 16, line: UInt = #line) throws -> UIFont {
        let font = try XCTUnwrap(
            UIFont(name: psName, size: size),
            "\(psName) must resolve via UIKit in this process after DSFonts.registerAll()",
            line: line
        )
        XCTAssertEqual(
            font.fontName, psName,
            "\(psName) must resolve to the canonical bundled face (actual case)",
            line: line
        )
        return font
    }

    /// Asserts the descriptor produced by the real serif pipeline carries a
    /// single-entry cascade list ending at the expected CJK face.
    private func requireCJKCascade(
        _ descriptor: UIFontDescriptor?,
        contains cjkPS: String,
        line: UInt = #line
    ) throws {
        let descriptor = try XCTUnwrap(
            descriptor,
            "serif descriptor must be built from real bundled faces (no system fallback)",
            line: line
        )
        let cascade = try XCTUnwrap(
            descriptor.object(forKey: .cascadeList) as? [UIFontDescriptor],
            "cascadeList attribute must be present on the serif descriptor",
            line: line
        )
        XCTAssertEqual(cascade.count, 1, "the serif cascade must carry exactly one CJK fallback face", line: line)
        XCTAssertEqual(
            cascade.first?.postscriptName, cjkPS,
            "CJK fallback must fall back at the matching weight",
            line: line
        )
    }

    // MARK: - Real UIKit resolved face + cascade: regular

    func testSerifRegularReturnsFont() throws {
        let faces = DSFonts.serifFacePostScriptNames(weight: .regular, italic: false)
        XCTAssertEqual(faces.latin, "SourceSerif4-Regular")
        XCTAssertEqual(faces.cjk, "SourceHanSerifSC-Regular")

        _ = try requireFace("SourceSerif4-Regular")
        _ = try requireFace("SourceHanSerifSC-Regular")

        try requireCJKCascade(
            DSFonts.serifUIFontDescriptor(size: 16, weight: .regular, italic: false),
            contains: "SourceHanSerifSC-Regular"
        )
        XCTAssertEqual(DSFonts.serifUIFont(size: 16, weight: .regular).fontName, "SourceSerif4-Regular")

        XCTAssertNoThrow(_ = DSFonts.serif(size: 16, weight: .regular))
    }

    // MARK: - Requested medium resolves to the nearest real bundled face

    func testSerifMediumReturnsFont() throws {
        // There is no genuine Latin Medium face: SourceSerif4-Medium.ttf is a
        // byte-identical copy of SourceSerif4-Regular.ttf (PS SourceSerif4-Regular).
        XCTAssertNil(
            UIFont(name: "SourceSerif4-Medium", size: 18),
            "the fictitious SourceSerif4-Medium face must not exist in the bundle"
        )

        let faces = DSFonts.serifFacePostScriptNames(weight: .medium, italic: false)
        XCTAssertEqual(
            faces.latin, "SourceSerif4-Semibold",
            "requested medium must resolve to the nearest real bundled face (Semibold)"
        )
        XCTAssertEqual(faces.cjk, "SourceHanSerifSC-Medium", "CJK keeps its matching-weight fallback")

        _ = try requireFace("SourceSerif4-Semibold")
        _ = try requireFace("SourceHanSerifSC-Medium")

        try requireCJKCascade(
            DSFonts.serifUIFontDescriptor(size: 18, weight: .medium, italic: false),
            contains: "SourceHanSerifSC-Medium"
        )
        XCTAssertEqual(
            DSFonts.serifUIFont(size: 18, weight: .medium).fontName, "SourceSerif4-Semibold",
            "the resolved Latin face must be the real bundled Semibold face"
        )

        XCTAssertNoThrow(_ = DSFonts.serif(size: 18, weight: .medium))
    }

    // MARK: - Real UIKit resolved face + cascade: semibold

    func testSerifSemiboldReturnsFont() throws {
        let faces = DSFonts.serifFacePostScriptNames(weight: .semibold, italic: false)
        XCTAssertEqual(faces.latin, "SourceSerif4-Semibold", "actual case canonical PostScript name")
        XCTAssertEqual(faces.cjk, "SourceHanSerifSC-SemiBold")

        _ = try requireFace("SourceSerif4-Semibold")
        _ = try requireFace("SourceHanSerifSC-SemiBold")

        try requireCJKCascade(
            DSFonts.serifUIFontDescriptor(size: 20, weight: .semibold, italic: false),
            contains: "SourceHanSerifSC-SemiBold"
        )
        XCTAssertEqual(DSFonts.serifUIFont(size: 20, weight: .semibold).fontName, "SourceSerif4-Semibold")

        XCTAssertNoThrow(_ = DSFonts.serif(size: 20, weight: .semibold))
    }

    // MARK: - Real UIKit resolved face + cascade: italic

    func testSerifItalicReturnsFont() throws {
        let faces = DSFonts.serifFacePostScriptNames(weight: .regular, italic: true)
        XCTAssertEqual(faces.latin, "SourceSerif4-It")
        XCTAssertEqual(faces.cjk, "SourceHanSerifSC-Regular", "CJK italic stays upright at the regular weight")

        _ = try requireFace("SourceSerif4-It")
        _ = try requireFace("SourceHanSerifSC-Regular")

        try requireCJKCascade(
            DSFonts.serifUIFontDescriptor(size: 16, weight: .regular, italic: true),
            contains: "SourceHanSerifSC-Regular"
        )
        XCTAssertEqual(DSFonts.serifUIFont(size: 16, italic: true).fontName, "SourceSerif4-It")

        XCTAssertNoThrow(_ = DSFonts.serif(size: 16, italic: true))
    }

    // MARK: - Cascade list is wired for every supported face combination

    /// A missing bundled face is a hard failure, not a skip: the serif chain
    /// must resolve real UIKit faces for every supported combination.
    func testSerifCascadeListContainsCJKFace() throws {
        let cases: [(weight: Font.Weight, cjk: String)] = [
            (.regular, "SourceHanSerifSC-Regular"),
            (.medium, "SourceHanSerifSC-Medium"),
            (.semibold, "SourceHanSerifSC-SemiBold"),
        ]
        for entry in cases {
            let faces = DSFonts.serifFacePostScriptNames(weight: entry.weight, italic: false)
            _ = try requireFace(faces.latin)
            _ = try requireFace(faces.cjk)
            try requireCJKCascade(
                DSFonts.serifUIFontDescriptor(size: 16, weight: entry.weight, italic: false),
                contains: entry.cjk
            )
        }
        try requireCJKCascade(
            DSFonts.serifUIFontDescriptor(size: 16, weight: .regular, italic: true),
            contains: "SourceHanSerifSC-Regular"
        )
    }

    // MARK: - Registration idempotence + UIKit process availability

    func testRegisterAllIsIdempotentAndFacesStayAvailable() {
        // Repeated registration (DayPageApp.init + test bundle) must be a
        // no-op that neither crashes nor makes any face unavailable.
        DSFonts.registerAll()
        DSFonts.registerAll()

        for psName in [
            "SourceSerif4-Regular",
            "SourceSerif4-Semibold",
            "SourceSerif4-It",
            "SourceHanSerifSC-Regular",
            "SourceHanSerifSC-Medium",
            "SourceHanSerifSC-SemiBold",
        ] {
            XCTAssertNotNil(
                UIFont(name: psName, size: 12),
                "\(psName) must stay resolvable in the UIKit process after repeated registerAll() calls"
            )
        }
        // The fictitious Medium name must remain absent — registration must
        // not have introduced it via the byte-duplicate Medium file.
        XCTAssertNil(UIFont(name: "SourceSerif4-Medium", size: 12))
    }

    // MARK: - serifUIFont() resolves the real bundled face for every supported weight

    func testSerifUIFontMatchesRealBundledFaceForEverySupportedWeight() {
        let expectations: [(weight: Font.Weight, italic: Bool, latin: String)] = [
            (.regular, false, "SourceSerif4-Regular"),
            (.medium, false, "SourceSerif4-Semibold"),
            (.semibold, false, "SourceSerif4-Semibold"),
            (.regular, true, "SourceSerif4-It"),
            (.semibold, true, "SourceSerif4-It"),
        ]
        for entry in expectations {
            let uiFont = DSFonts.serifUIFont(size: 14, weight: entry.weight, italic: entry.italic)
            XCTAssertEqual(
                uiFont.fontName, entry.latin,
                "serifUIFont must resolve the real bundled Latin face, not the system fallback"
            )
            XCTAssertNoThrow(_ = DSFonts.serif(size: 14, weight: entry.weight, italic: entry.italic))
        }
    }
}
