import SwiftUI
import DayPageServices

// MARK: - Font Registration

enum DSFonts {
    // 字体族名称 — 与注册的自定义字体匹配，不可用时回退到系统字体
    static let headline = "Space Grotesk"
    static let body = "Inter"
    static let mono = "JetBrains Mono"

    /// Idempotent guard so the registration cost is paid exactly once, even
    /// if callsites accidentally invoke `registerAll()` from multiple paths
    /// (DayPageApp.init + a test bundle, for instance). Issue #29.
    private static var hasRegistered = false

    /// Real faces that genuinely exist in the bundle, keyed by the canonical
    /// PostScript name used at resolution time, with bundle file names in
    /// fallback order. Font-file inspection (2026-10-02) established that
    /// `SourceSerif4-Medium.ttf` is a byte-identical copy of
    /// `SourceSerif4-Regular.ttf` whose real PostScript name is
    /// `SourceSerif4-Regular` — there is no genuine Latin Medium face. So
    /// `SourceSerif4-Medium.ttf` is only a fallback *file* candidate for the
    /// `SourceSerif4-Regular` face and is never a face of its own: treating
    /// the fictitious `SourceSerif4-Medium` name as a missing face would
    /// re-register the same Regular face (a duplicate registration) purely
    /// because the fictitious name can never resolve.
    private static let bundledFaces: [(psName: String, fileNames: [String])] = [
        ("SpaceGrotesk-Light", ["SpaceGrotesk-Light.ttf"]),
        ("SpaceGrotesk-Regular", ["SpaceGrotesk-Regular.ttf"]),
        ("SpaceGrotesk-Medium", ["SpaceGrotesk-Medium.ttf"]),
        // The SemiBold file is a duplicate of the real Bold face.
        ("SpaceGrotesk-Bold", ["SpaceGrotesk-Bold.ttf", "SpaceGrotesk-SemiBold.ttf"]),
        ("Inter-Light", ["Inter-Light.ttf"]),
        ("Inter-Regular", ["Inter-Regular.ttf"]),
        ("Inter-Medium", ["Inter-Medium.ttf"]),
        ("Inter-SemiBold", ["Inter-SemiBold.ttf"]),
        ("Inter-Bold", ["Inter-Bold.ttf"]),
        ("JetBrainsMono-Regular", ["JetBrainsMono-Regular.ttf"]),
        ("JetBrainsMono-Medium", ["JetBrainsMono-Medium.ttf"]),
        ("SourceSerif4-Regular", ["SourceSerif4-Regular.ttf", "SourceSerif4-Medium.ttf"]),
        ("SourceSerif4-Semibold", ["SourceSerif4-SemiBold.ttf"]),
        ("SourceSerif4-It", ["SourceSerif4-It.ttf"]),
        ("SourceHanSerifSC-Regular", ["SourceHanSerifSC-Regular.otf"]),
        ("SourceHanSerifSC-Medium", ["SourceHanSerifSC-Medium.otf"]),
        ("SourceHanSerifSC-SemiBold", ["SourceHanSerifSC-SemiBold.otf"]),
    ]

    /// 从应用包中注册自定义字体。
    /// 在应用启动时调用一次（例如在 DayPageApp.init 中）。
    /// 如果字体文件未打包，SwiftUI 将回退到系统字体。
    ///
    /// Implementation note (issue #29): registration MUST run synchronously
    /// before the first SwiftUI body executes — `Font.custom(name, ...)`
    /// falls back to the system font when the family is not yet registered,
    /// and SwiftUI does not redraw the view tree just because a new font
    /// arrives later. Deferring this to `Task.detached` caused the first
    /// rendered frame to use system fonts and "jump" to the brand fonts on
    /// the second frame.
    ///
    /// To keep that work fast, we batch every URL into a single
    /// `CTFontManagerRegisterFontURLs` call rather than issuing one
    /// CoreText round-trip per face. That single batched call is ~3× faster
    /// than 19 individual ones on cold launch.
    static func registerAll() {
        // Once-per-process idempotence: repeated callsites (DayPageApp.init +
        // test bundles) must not re-register anything.
        guard !hasRegistered else { return }
        hasRegistered = true

        // Synchronously register ONLY genuinely missing real faces. The old
        // wholesale "UIAppFonts declared ⇒ return" shortcut assumed every
        // declared face had materialized and left partially-registered hosts
        // (stripped test hosts, previews) with no usable faces at all. The
        // per-face `UIFont(name:)` probe is the UIKit-process availability
        // check: a face counts as available only when UIKit can resolve it
        // right now, so already-registered faces are never registered twice.
        var urls: [URL] = []
        var seen = Set<URL>()
        for face in bundledFaces where UIFont(name: face.psName, size: 12) == nil {
            guard let url = face.fileNames.compactMap({ fontFileURL(named: $0) }).first,
                  seen.insert(url).inserted else { continue }
            urls.append(url)
        }
        guard !urls.isEmpty else { return }

        // `enabled: true` is load-bearing. Per CTFontManager.h
        // (`CTFontManagerRegisterFontURLs`), `enabled == false` registers the
        // faces *disabled* for font-descriptor matching, so `UIFont(name:)`
        // keeps failing and every serif request silently falls back to the
        // system font. Synchronous, process-scope registration makes the
        // faces available to UIKit before the first SwiftUI body evaluates
        // (issue #29).
        CTFontManagerRegisterFontURLs(
            urls as CFArray,
            .process,
            true, // enabled — faces participate in font matching immediately
            nil   // no error reporting; missing faces silently fall back
        )
    }

    /// Looks up a bundled font file in the main bundle first, then in every
    /// loaded bundle/framework, so registration also works in test hosts and
    /// previews where the application's Info.plist (and its `UIAppFonts`
    /// entries) is absent.
    private static func fontFileURL(named fileName: String) -> URL? {
        let ns = fileName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        for bundle in [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks {
            if let url = bundle.url(forResource: base, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    // MARK: - Resolved Font Helpers (with system fallbacks)

    /// Pass `relativeTo:` to make the returned font track Dynamic Type — the
    /// point size is treated as the value at the default (.large) content size
    /// and scales with the given text style. `nil` keeps the fixed-size
    /// behaviour for legacy call sites.
    static func spaceGrotesk(size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle? = nil) -> Font {
        if let textStyle {
            return Font.custom(headline, size: size, relativeTo: textStyle).weight(weight)
        }
        return .custom(headline, size: size).weight(weight)
    }

    static func inter(size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle? = nil) -> Font {
        if let textStyle {
            return Font.custom(body, size: size, relativeTo: textStyle).weight(weight)
        }
        return .custom(body, size: size).weight(weight)
    }

    static func jetBrainsMono(size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle? = nil) -> Font {
        if let textStyle {
            return Font.custom(mono, size: size, relativeTo: textStyle).weight(weight)
        }
        return .custom(mono, size: size).weight(weight)
    }

    // MARK: - Cascading Serif (Source Serif 4 + Source Han Serif SC)

    /// Canonical PostScript names of the serif faces that genuinely exist in
    /// the bundle (font-file inspection, 2026-10-02):
    ///
    ///   • `SourceSerif4-Regular.ttf`  → `SourceSerif4-Regular`
    ///   • `SourceSerif4-Medium.ttf`   → `SourceSerif4-Regular` — a byte-identical
    ///     copy of the Regular face; there is NO genuine Latin Medium face.
    ///   • `SourceSerif4-SemiBold.ttf` → `SourceSerif4-Semibold` (lowercase “b”)
    ///   • `SourceSerif4-It.ttf`       → `SourceSerif4-It`
    ///   • `SourceHanSerifSC-{Regular,Medium,SemiBold}.otf` → same names.
    ///
    /// Requested `.medium` therefore resolves to the nearest real bundled
    /// Latin face — `SourceSerif4-Semibold` (600) — instead of asking for the
    /// nonexistent `SourceSerif4-Medium` name, which made the whole serif
    /// chain fall back to the system font. The CJK cascade keeps its
    /// matching-weight face (`.medium` → `SourceHanSerifSC-Medium`), and
    /// italic keeps its dedicated Latin face (CJK stays upright — Source Han
    /// Serif SC has no italic face).
    ///
    /// Shared by `serif(...)` and `serifUIFont(...)` so the SwiftUI and UIKit
    /// serif surfaces cannot drift apart.
    static func serifFacePostScriptNames(weight: Font.Weight, italic: Bool) -> (latin: String, cjk: String) {
        let latin: String
        if italic {
            latin = "SourceSerif4-It"
        } else {
            switch weight {
            case .medium:   latin = "SourceSerif4-Semibold" // nearest real bundled face; no Medium face exists
            case .semibold: latin = "SourceSerif4-Semibold"
            default:        latin = "SourceSerif4-Regular"
            }
        }
        let cjk: String
        switch weight {
        case .medium:   cjk = "SourceHanSerifSC-Medium"
        case .semibold: cjk = "SourceHanSerifSC-SemiBold"
        default:        cjk = "SourceHanSerifSC-Regular"
        }
        return (latin, cjk)
    }

    /// Single construction point shared by `serif(...)` and `serifUIFont(...)`:
    /// a descriptor for the resolved Latin face carrying a matching-weight CJK
    /// cascade, or `nil` when any required bundled face is missing (callers
    /// then fall back to the system serif design).
    static func serifUIFontDescriptor(size: CGFloat, weight: Font.Weight, italic: Bool) -> UIFontDescriptor? {
        let faces = serifFacePostScriptNames(weight: weight, italic: italic)
        guard
            let latinBase = UIFont(name: faces.latin, size: size),
            let cjkBase   = UIFont(name: faces.cjk,   size: size)
        else { return nil }
        return latinBase.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName.cascadeList: [cjkBase.fontDescriptor]
        ])
    }

    /// Returns a SwiftUI Font backed by a UIFontDescriptor cascade list so that:
    ///   • Latin characters render via Source Serif 4 (Regular/Semibold or italic —
    ///     see `serifFacePostScriptNames(weight:italic:)` for the nearest-real-face
    ///     mapping used for requested `.medium`)
    ///   • CJK characters automatically fall back to Source Han Serif SC at the same weight.
    ///     (Source Han Serif SC has no italic face; iOS renders CJK in upright style even
    ///      when italic is requested — this is the standard platform behaviour for CJK fonts.)
    /// Falls back to the system serif design if any required font face is absent from the bundle.
    ///
    /// Dynamic Type: fonts built from a concrete `UIFont` do not scale on their
    /// own (unlike `Font.custom(_:size:relativeTo:)`), so when `relativeTo:` is
    /// given we scale the point size through `UIFontMetrics` at resolution time.
    /// The serif `DSType` levels are computed properties so they re-resolve
    /// whenever a view body re-evaluates after a size-category change.
    /// `maxSize` caps that scaling for display-size levels, mirroring the
    /// `.accessibility1` clamp the sans-serif display modifiers apply.
    static func serif(
        size: CGFloat,
        weight: Font.Weight = .regular,
        italic: Bool = false,
        relativeTo textStyle: Font.TextStyle? = nil,
        maxSize: CGFloat? = nil
    ) -> Font {
        var size = size
        if let textStyle {
            size = UIFontMetrics(forTextStyle: textStyle.uiTextStyle).scaledValue(for: size)
            if let maxSize {
                size = min(size, maxSize)
            }
        }

        // Resolved through the shared face table + cascade construction.
        if let descriptor = serifUIFontDescriptor(size: size, weight: weight, italic: italic) {
            return Font(UIFont(descriptor: descriptor, size: size))
        }

        // A required face is missing from the bundle — fall back to system serif.
        let base = Font.system(size: size, weight: weight, design: .serif)
        return italic ? base.italic() : base
    }

    /// UIKit twin of `serif(size:weight:italic:)` for surfaces that live in
    /// UIKit-land (the live markdown editor's NSAttributedString styling).
    /// Same shared PostScript resolution + CJK cascade; falls back to the
    /// system serif design when a bundled face is missing.
    static func serifUIFont(size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> UIFont {
        if let descriptor = serifUIFontDescriptor(size: size, weight: weight, italic: italic) {
            return UIFont(descriptor: descriptor, size: size)
        }

        let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
            .withDesign(.serif) ?? UIFont.systemFont(ofSize: size).fontDescriptor
        var traits: UIFontDescriptor.SymbolicTraits = []
        if italic { traits.insert(.traitItalic) }
        if weight == .semibold || weight == .medium { traits.insert(.traitBold) }
        let traited = descriptor.withSymbolicTraits(traits) ?? descriptor
        return UIFont(descriptor: traited, size: size)
    }
}

// MARK: - Font.TextStyle Bridging

private extension Font.TextStyle {
    /// UIKit counterpart, used to drive `UIFontMetrics` for UIFont-backed
    /// (cascading serif) fonts that cannot use `Font.custom(relativeTo:)`.
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle:  return .largeTitle
        case .title:       return .title1
        case .title2:      return .title2
        case .title3:      return .title3
        case .headline:    return .headline
        case .subheadline: return .subheadline
        case .body:        return .body
        case .callout:     return .callout
        case .footnote:    return .footnote
        case .caption:     return .caption1
        case .caption2:    return .caption2
        @unknown default:  return .body
        }
    }
}

// MARK: - Typography Levels

/// Every level anchors to the system text style closest to its semantic role
/// (`relativeTo:`), so custom fonts scale with Dynamic Type: display/hero →
/// `.largeTitle`, section headers → `.title`/`.title2`/`.title3`, emphasized
/// 18pt copy → `.headline`, running text → `.body`/`.subheadline`, and
/// captions/labels/mono chips → `.footnote`/`.caption`/`.caption2`. The point
/// size is the design value at the default (.large) content size. Serif
/// levels are computed properties because their UIFont cascade resolves the
/// scaled size eagerly (see `DSFonts.serif`).
enum DSType {
    // H1: 32 / Space Grotesk 700
    static let h1: Font = DSFonts.spaceGrotesk(size: 32, weight: .bold, relativeTo: .largeTitle)

    // H2: 22 / Space Grotesk SemiBold
    static let h2: Font = DSFonts.spaceGrotesk(size: 22, weight: .semibold, relativeTo: .title2)

    // Headline-MD: 24 / Space Grotesk 700 uppercase
    static let headlineMD: Font = DSFonts.spaceGrotesk(size: 24, weight: .bold, relativeTo: .title)

    // Headline-Caps: 18 / Space Grotesk 700 uppercase (tracking widest)
    static let headlineCaps: Font = DSFonts.spaceGrotesk(size: 18, weight: .bold, relativeTo: .headline)

    // Section-Label: 13 / Space Grotesk 700 uppercase
    static let sectionLabel: Font = DSFonts.spaceGrotesk(size: 13, weight: .bold, relativeTo: .footnote)

    // Title-SM: 20 / Inter 600
    static let titleSM: Font = DSFonts.inter(size: 20, weight: .semibold, relativeTo: .title3)

    // Body-MD: 16 / Inter 400
    static let bodyMD: Font = DSFonts.inter(size: 16, weight: .regular, relativeTo: .body)

    // Body-SM: 14 / Inter 400
    static let bodySM: Font = DSFonts.inter(size: 14, weight: .regular, relativeTo: .subheadline)

    // Caption: 13 / Inter Medium
    static let caption: Font = DSFonts.inter(size: 13, weight: .medium, relativeTo: .footnote)

    // Label: 11 / Space Grotesk Bold uppercase
    static let label: Font = DSFonts.spaceGrotesk(size: 11, weight: .bold, relativeTo: .caption2)

    // Label-SM: 12 / Inter 500
    static let labelSM: Font = DSFonts.inter(size: 12, weight: .medium, relativeTo: .caption)

    // Label-XS: 10 / Inter 500 or JetBrains Mono
    static let labelXS: Font = DSFonts.inter(size: 10, weight: .medium, relativeTo: .caption2)

    // Mono-11: 11 / JetBrains Mono 500 uppercase (chips, timestamps)
    static let mono11: Font = DSFonts.jetBrainsMono(size: 11, weight: .medium, relativeTo: .caption2)

    // Mono-10: 10 / JetBrains Mono 400 uppercase
    static let mono10: Font = DSFonts.jetBrainsMono(size: 10, weight: .regular, relativeTo: .caption2)

    // Mono-9: 9 / JetBrains Mono 400 uppercase (badges)
    static let mono9: Font = DSFonts.jetBrainsMono(size: 9, weight: .regular, relativeTo: .caption2)

    // MARK: - V4 Liquid Glass Serif Levels
    // Computed (not stored) so UIFontMetrics re-resolves on size-category
    // changes. Display levels carry a `maxSize` cap ≈ the .accessibility1
    // scale of their anchor style, matching the sans-serif display clamp.

    /// Serif body 16pt — memo card body copy.
    static var serifBody16: Font { DSFonts.serif(size: 16, weight: .regular, relativeTo: .body) }
    /// Serif body 18pt — Daily Page card lead summary.
    static var serifBody18: Font { DSFonts.serif(size: 18, weight: .regular, relativeTo: .headline) }
    /// Serif body 20pt — quoted voice transcript.
    static var serifBody20: Font { DSFonts.serif(size: 20, weight: .regular, relativeTo: .title3) }
    /// Serif italic 18pt — voice-memo "quote" style.
    static var serifQuote: Font { DSFonts.serif(size: 18, italic: true, relativeTo: .headline) }
    /// Serif display 28pt — Today header date.
    static var serifDisplay28: Font { DSFonts.serif(size: 28, weight: .semibold, relativeTo: .title, maxSize: 34) }
    /// Serif display 32pt — sidebar date / large headers.
    static var serifDisplay32: Font { DSFonts.serif(size: 32, weight: .semibold, relativeTo: .largeTitle, maxSize: 41) }
}

// MARK: - View Modifiers

struct H1Modifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DSType.h1)
            .dynamicTypeSize(.xSmall ... .accessibility2)
            .minimumScaleFactor(0.80)
            .accessibilityAddTraits(.isHeader)
    }
}

struct H2Modifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DSType.h2)
            .dynamicTypeSize(.xSmall ... .accessibility2)
            .minimumScaleFactor(0.80)
    }
}

struct CaptionStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.font(DSType.caption)
    }
}

struct LabelStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.font(DSType.label).textCase(.uppercase).tracking(0.5)
    }
}

struct HeadlineMDModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DSType.headlineMD)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

struct HeadlineCapsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DSType.headlineCaps)
            .textCase(.uppercase)
            .tracking(2)
    }
}

struct SectionLabelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DSType.sectionLabel)
            .textCase(.uppercase)
            .tracking(1.5)
    }
}

struct BodyMDModifier: ViewModifier {
    @ObservedObject private var appSettings = AppSettings.shared

    func body(content: Content) -> some View {
        // fontSizeAdjust.delta shifts the base size *before* Dynamic Type
        // scaling — the two mechanisms compose (relativeTo scales `adjusted`).
        let baseSize: CGFloat = 16
        let adjusted = baseSize + appSettings.fontSizeAdjust.delta
        let spacing = max(0, 4 + appSettings.cardDensity.lineSpacingDelta)
        content
            .font(DSFonts.inter(size: adjusted, weight: .regular, relativeTo: .body))
            .lineSpacing(spacing)
            .dynamicTypeSize(.xSmall ... .xxxLarge)
            .minimumScaleFactor(0.85)
    }
}

struct BodySMModifier: ViewModifier {
    @ObservedObject private var appSettings = AppSettings.shared

    func body(content: Content) -> some View {
        // Same composition as BodyMDModifier: delta first, then Dynamic Type.
        let baseSize: CGFloat = 14
        let adjusted = baseSize + appSettings.fontSizeAdjust.delta
        let spacing = max(0, 3 + appSettings.cardDensity.lineSpacingDelta)
        content
            .font(DSFonts.inter(size: adjusted, weight: .regular, relativeTo: .subheadline))
            .lineSpacing(spacing)
            .dynamicTypeSize(.xSmall ... .xxxLarge)
            .minimumScaleFactor(0.85)
    }
}

struct LabelSMModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DSType.labelSM)
    }
}

struct MonoLabelModifier: ViewModifier {
    let size: CGFloat
    func body(content: Content) -> some View {
        content
            .font(DSFonts.jetBrainsMono(size: size, weight: .medium, relativeTo: .caption2))
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

// MARK: - View Extensions

extension View {
    // v3 shorthand (Style suffix)
    func h2Style() -> some View { modifier(H2Modifier()) }
    func captionStyle() -> some View { modifier(CaptionStyleModifier()) }
    func labelStyle() -> some View { modifier(LabelStyleModifier()) }

    // v3 short names (no suffix) — use these in new code
    func h1() -> some View { modifier(H1Modifier()) }
    func bodyText() -> some View { modifier(BodyMDModifier()) }
    func captionText() -> some View { modifier(CaptionStyleModifier()) }
    func labelText() -> some View { modifier(LabelStyleModifier()) }

    // Legacy / existing
    func headlineMDStyle() -> some View { modifier(HeadlineMDModifier()) }
    func headlineCapsStyle() -> some View { modifier(HeadlineCapsModifier()) }
    func sectionLabelStyle() -> some View { modifier(SectionLabelModifier()) }
    func bodyMDStyle() -> some View { modifier(BodyMDModifier()) }
    func bodySMStyle() -> some View { modifier(BodySMModifier()) }
    func labelSMStyle() -> some View { modifier(LabelSMModifier()) }
    func monoLabelStyle(size: CGFloat = 11) -> some View { modifier(MonoLabelModifier(size: size)) }
}
