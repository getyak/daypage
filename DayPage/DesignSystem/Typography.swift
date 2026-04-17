import SwiftUI

// MARK: - Font Registration

enum DSFonts {
    // Font family names — matched against registered custom fonts, fall back to system if unavailable
    static let headline = "Space Grotesk"
    static let body = "Inter"
    static let mono = "JetBrains Mono"

    /// Register custom fonts from app bundle.
    /// Call once at app startup (e.g. in DayPageApp.init).
    /// If the font files are not bundled, SwiftUI falls back to system fonts.
    static func registerAll() {
        let names = [
            "SpaceGrotesk-Light", "SpaceGrotesk-Regular", "SpaceGrotesk-Medium",
            "SpaceGrotesk-SemiBold", "SpaceGrotesk-Bold",
            "Inter-Light", "Inter-Regular", "Inter-Medium",
            "Inter-SemiBold", "Inter-Bold",
            "JetBrainsMono-Regular", "JetBrainsMono-Medium",
        ]
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") ??
                         Bundle.main.url(forResource: name, withExtension: "otf") {
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
}

// MARK: - View Modifiers

struct H1Modifier: ViewModifier {
    func body(content: Content) -> some View {
        content.font(DSType.h1)
    }
}

struct H2Modifier: ViewModifier {
    func body(content: Content) -> some View {
        content.font(DSType.h2)
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
    func body(content: Content) -> some View {
        content
            .font(DSType.bodyMD)
            .lineSpacing(4)
    }
}

struct BodySMModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DSType.bodySM)
            .lineSpacing(3)
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
