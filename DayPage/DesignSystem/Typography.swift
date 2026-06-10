import SwiftUI

// MARK: - Font Registration

enum DSFonts {
    // 字体族名称 — 与注册的自定义字体匹配，不可用时回退到系统字体
    static let headline = "Space Grotesk"
    static let body = "Inter"
    static let mono = "JetBrains Mono"

    /// 从应用包中注册自定义字体。
    /// 在应用启动时调用一次（例如在 DayPageApp.init 中）。
    /// 如果字体文件未打包，SwiftUI 将回退到系统字体。
    static func registerAll() {
        let ttfNames = [
            "SpaceGrotesk-Light", "SpaceGrotesk-Regular", "SpaceGrotesk-Medium",
            "SpaceGrotesk-SemiBold", "SpaceGrotesk-Bold",
            "Inter-Light", "Inter-Regular", "Inter-Medium",
            "Inter-SemiBold", "Inter-Bold",
            "JetBrainsMono-Regular", "JetBrainsMono-Medium",
            "SourceSerif4-Regular", "SourceSerif4-Medium",
            "SourceSerif4-SemiBold", "SourceSerif4-It",
        ]
        let otfNames = [
            "SourceHanSerifSC-Regular", "SourceHanSerifSC-Medium", "SourceHanSerifSC-SemiBold",
        ]
        for name in ttfNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        for name in otfNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "otf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    // MARK: - Resolved Font Helpers (with system fallbacks)

    static func spaceGrotesk(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(headline, size: size).weight(weight)
    }

    static func inter(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(body, size: size).weight(weight)
    }

    static func jetBrainsMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(mono, size: size).weight(weight)
    }

    // MARK: - Cascading Serif (Source Serif 4 + Source Han Serif SC)

    /// Returns a SwiftUI Font backed by a UIFontDescriptor cascade list so that:
    ///   • Latin characters render via Source Serif 4 (Regular/Medium/SemiBold or italic)
    ///   • CJK characters automatically fall back to Source Han Serif SC at the same weight.
    ///     (Source Han Serif SC has no italic face; iOS renders CJK in upright style even
    ///      when italic is requested — this is the standard platform behaviour for CJK fonts.)
    /// Falls back to the system serif design if any required font face is absent from the bundle.
    static func serif(size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        // PostScript name mapping for the primary Latin face.
        let latinPS: String
        if italic {
            latinPS = "SourceSerif4-It"
        } else {
            switch weight {
            case .medium:     latinPS = "SourceSerif4-Medium"
            case .semibold:   latinPS = "SourceSerif4-SemiBold"
            default:          latinPS = "SourceSerif4-Regular"
            }
        }

        // PostScript name mapping for the CJK fallback face.
        let cjkPS: String
        switch weight {
        case .medium:   cjkPS = "SourceHanSerifSC-Medium"
        case .semibold: cjkPS = "SourceHanSerifSC-SemiBold"
        default:        cjkPS = "SourceHanSerifSC-Regular"
        }

        guard
            let latinBase = UIFont(name: latinPS, size: size),
            let cjkBase   = UIFont(name: cjkPS,   size: size)
        else {
            // Either face is missing from the bundle — fall back to system serif.
            let base = Font.system(size: size, weight: weight, design: .serif)
            return italic ? base.italic() : base
        }

        let cjkDescriptor = cjkBase.fontDescriptor
        let cascadeDescriptor = latinBase.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName.cascadeList: [cjkDescriptor]
        ])
        let cascadedFont = UIFont(descriptor: cascadeDescriptor, size: size)
        return Font(cascadedFont)
    }
}

// MARK: - Typography Levels

enum DSType {
    // Display-LG: 56 / Space Grotesk 700 uppercase
    static let displayLG: Font = DSFonts.spaceGrotesk(size: 56, weight: .bold)

    // H1: 32 / Space Grotesk 700
    static let h1: Font = DSFonts.spaceGrotesk(size: 32, weight: .bold)

    // H2: 22 / Space Grotesk SemiBold
    static let h2: Font = DSFonts.spaceGrotesk(size: 22, weight: .semibold)

    // Headline-MD: 24 / Space Grotesk 700 uppercase
    static let headlineMD: Font = DSFonts.spaceGrotesk(size: 24, weight: .bold)

    // Headline-Caps: 18 / Space Grotesk 700 uppercase (tracking widest)
    static let headlineCaps: Font = DSFonts.spaceGrotesk(size: 18, weight: .bold)

    // Section-Label: 13 / Space Grotesk 700 uppercase
    static let sectionLabel: Font = DSFonts.spaceGrotesk(size: 13, weight: .bold)

    // Title-SM: 20 / Inter 600
    static let titleSM: Font = DSFonts.inter(size: 20, weight: .semibold)

    // Body-MD: 16 / Inter 400
    static let bodyMD: Font = DSFonts.inter(size: 16, weight: .regular)

    // Body-SM: 14 / Inter 400
    static let bodySM: Font = DSFonts.inter(size: 14, weight: .regular)

    // Caption: 13 / Inter Medium
    static let caption: Font = DSFonts.inter(size: 13, weight: .medium)

    // Label: 11 / Space Grotesk Bold uppercase
    static let label: Font = DSFonts.spaceGrotesk(size: 11, weight: .bold)

    // Label-SM: 12 / Inter 500
    static let labelSM: Font = DSFonts.inter(size: 12, weight: .medium)

    // Label-XS: 10 / Inter 500 or JetBrains Mono
    static let labelXS: Font = DSFonts.inter(size: 10, weight: .medium)

    // Mono-11: 11 / JetBrains Mono 500 uppercase (chips, timestamps)
    static let mono11: Font = DSFonts.jetBrainsMono(size: 11, weight: .medium)

    // Mono-10: 10 / JetBrains Mono 400 uppercase
    static let mono10: Font = DSFonts.jetBrainsMono(size: 10, weight: .regular)

    // Mono-9: 9 / JetBrains Mono 400 uppercase (badges)
    static let mono9: Font = DSFonts.jetBrainsMono(size: 9, weight: .regular)

    // MARK: - V4 Liquid Glass Serif Levels

    /// Serif body 16pt — memo card body copy.
    static let serifBody16: Font = DSFonts.serif(size: 16, weight: .regular)
    /// Serif body 18pt — Daily Page card lead summary.
    static let serifBody18: Font = DSFonts.serif(size: 18, weight: .regular)
    /// Serif body 20pt — quoted voice transcript.
    static let serifBody20: Font = DSFonts.serif(size: 20, weight: .regular)
    /// Serif italic 18pt — voice-memo "quote" style.
    static let serifQuote: Font = DSFonts.serif(size: 18, italic: true)
    /// Serif display 28pt — Today header date.
    static let serifDisplay28: Font = DSFonts.serif(size: 28, weight: .semibold)
    /// Serif display 32pt — sidebar date / large headers.
    static let serifDisplay32: Font = DSFonts.serif(size: 32, weight: .semibold)
    /// Serif display 56pt — Today hero date title (museum-aesthetic, always-on).
    static let serifDisplay56: Font = DSFonts.serif(size: 56, weight: .semibold)
}

// MARK: - View Modifiers

struct H1Modifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DSType.h1)
            .dynamicTypeSize(.xSmall ... .accessibility2)
            .minimumScaleFactor(0.80)
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

struct DisplayLGModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DSType.displayLG)
            .textCase(.uppercase)
            .tracking(1)
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

struct TitleSMModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DSType.titleSM)
    }
}

struct BodyMDModifier: ViewModifier {
    @ObservedObject private var appSettings = AppSettings.shared

    func body(content: Content) -> some View {
        let baseSize: CGFloat = 16
        let adjusted = baseSize + appSettings.fontSizeAdjust.delta
        let spacing = max(0, 4 + appSettings.cardDensity.lineSpacingDelta)
        content
            .font(DSFonts.inter(size: adjusted, weight: .regular))
            .lineSpacing(spacing)
            .dynamicTypeSize(.xSmall ... .xxxLarge)
            .minimumScaleFactor(0.85)
    }
}

struct BodySMModifier: ViewModifier {
    @ObservedObject private var appSettings = AppSettings.shared

    func body(content: Content) -> some View {
        let baseSize: CGFloat = 14
        let adjusted = baseSize + appSettings.fontSizeAdjust.delta
        let spacing = max(0, 3 + appSettings.cardDensity.lineSpacingDelta)
        content
            .font(DSFonts.inter(size: adjusted, weight: .regular))
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

struct LabelXSModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DSType.labelXS)
    }
}

struct MonoLabelModifier: ViewModifier {
    let size: CGFloat
    func body(content: Content) -> some View {
        content
            .font(DSFonts.jetBrainsMono(size: size, weight: .medium))
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

// MARK: - View Extensions

extension View {
    // v3 shorthand (Style suffix)
    func h1Style() -> some View { modifier(H1Modifier()) }
    func h2Style() -> some View { modifier(H2Modifier()) }
    func captionStyle() -> some View { modifier(CaptionStyleModifier()) }
    func labelStyle() -> some View { modifier(LabelStyleModifier()) }

    // v3 short names (no suffix) — use these in new code
    func displayLG() -> some View { modifier(DisplayLGModifier()) }
    func h1() -> some View { modifier(H1Modifier()) }
    func h2() -> some View { modifier(H2Modifier()) }
    func bodyText() -> some View { modifier(BodyMDModifier()) }
    func captionText() -> some View { modifier(CaptionStyleModifier()) }
    func labelText() -> some View { modifier(LabelStyleModifier()) }
    func monoText(size: CGFloat = 11) -> some View { modifier(MonoLabelModifier(size: size)) }

    // Legacy / existing
    func displayLGStyle() -> some View { modifier(DisplayLGModifier()) }
    func headlineMDStyle() -> some View { modifier(HeadlineMDModifier()) }
    func headlineCapsStyle() -> some View { modifier(HeadlineCapsModifier()) }
    func sectionLabelStyle() -> some View { modifier(SectionLabelModifier()) }
    func titleSMStyle() -> some View { modifier(TitleSMModifier()) }
    func bodyMDStyle() -> some View { modifier(BodyMDModifier()) }
    func bodySMStyle() -> some View { modifier(BodySMModifier()) }
    func labelSMStyle() -> some View { modifier(LabelSMModifier()) }
    func labelXSStyle() -> some View { modifier(LabelXSModifier()) }
    func monoLabelStyle(size: CGFloat = 11) -> some View { modifier(MonoLabelModifier(size: size)) }
}
