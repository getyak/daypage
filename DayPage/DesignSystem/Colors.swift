import SwiftUI
import UIKit
import DayPageServices

// MARK: - Color Token Extensions

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// Adaptive color that switches between light and dark variants automatically.
    init(light: Color, dark: Color) {
        self = Color(UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

// MARK: - Design System Colors (v4 Liquid Glass + v3 Warm-White)

enum DSColor {

    // MARK: - V4 Liquid Glass Tokens (iOS 26 inspired)
    // Translucent warm-amber palette for glass surfaces. Use these in new
    // surfaces; v3 tokens below remain for compatibility while the codebase
    // migrates.

    /// Page background — warm cream in light, deep charcoal-brown in dark.
    /// Points at the generated token (`DSTokens.Colors.bgWarm`, from
    /// design-tokens/tokens.json) so this is the SINGLE source of truth for the
    /// page background. Previously this hand-wrote `dark #1A1410` while the
    /// generated source said `#1A1814` and the v3 `backgroundWarm` said
    /// `#1A1612` — three different charcoals for "the page background" left a
    /// visible seam where surfaces met. All three now resolve here.
    static let bgWarm        = DSTokens.Colors.bgWarm
    /// Standard glass fill — adaptive opacity glass layer.
    static let glassStd      = Color(light: Color(red: 1, green: 252/255, blue: 250/255, opacity: 0.62),
                                     dark: Color(red: 30/255, green: 22/255, blue: 14/255, opacity: 0.62))
    /// Elevated glass — used for sheets, modals, primary cards.
    static let glassHi       = Color(light: Color(red: 1, green: 252/255, blue: 250/255, opacity: 0.85),
                                     dark: Color(red: 38/255, green: 28/255, blue: 18/255, opacity: 0.85))
    /// Recessed glass — used for nested rows, secondary chips.
    static let glassLo       = Color(light: Color(red: 1, green: 252/255, blue: 250/255, opacity: 0.35),
                                     dark: Color(red: 26/255, green: 18/255, blue: 10/255, opacity: 0.35))
    /// Top-edge highlight that gives glass its "wet" rim.
    static let glassEdge     = Color(light: Color.white.opacity(0.55), dark: Color.white.opacity(0.12))
    /// Hairline border — adaptive warm ink line.
    static let glassRim      = Color(light: Color(hex: "2D1E0A").opacity(0.06),
                                     dark: Color(hex: "F5ECD8").opacity(0.08))
    /// Stronger hairline for elevated surfaces.
    static let glassRimD     = Color(light: Color(hex: "2D1E0A").opacity(0.10),
                                     dark: Color(hex: "F5ECD8").opacity(0.14))

    /// Primary ink — body copy, headlines.
    static let inkPrimary    = Color(light: Color(hex: "241B10"), dark: Color(hex: "F0E8DC"))
    /// Secondary ink — used alongside inkPrimary for subtly de-emphasized text.
    static let inkSecondary  = Color(light: Color(hex: "241B10").opacity(0.75), dark: Color(hex: "F0E8DC").opacity(0.75))
    /// Muted ink — secondary copy.
    static let inkMuted      = Color(light: Color(hex: "241B10").opacity(0.62), dark: Color(hex: "F0E8DC").opacity(0.62))
    /// Subtle ink — tertiary copy, disabled labels.
    static let inkSubtle     = Color(light: Color(hex: "241B10").opacity(0.38), dark: Color(hex: "F0E8DC").opacity(0.38))
    /// Faint ink — separators, decorative strokes.
    static let inkFaint      = Color(light: Color(hex: "241B10").opacity(0.18), dark: Color(hex: "F0E8DC").opacity(0.18))

    /// Amber accent — primary action, active state.
    static let amberAccent   = Color(hex: "A8541B")
    /// Deep amber — strong contrast on light glass.
    static let amberDeep     = Color(hex: "5D3000")
    /// Soft amber wash — hover, selected backgrounds.
    static let amberSoft     = Color(hex: "A8541B").opacity(0.10)
    /// Amber rim — accent borders, selected outlines.
    static let amberRim      = Color(hex: "A8541B").opacity(0.22)
    /// Amber glow — used in ambient light blobs.
    static let amberGlow     = Color(hex: "E8974D").opacity(0.45)

    // MARK: - Graph category hues (#828)
    //
    // The knowledge graph splits entities into three categories that must be
    // distinguishable at a glance in BOTH schemes. The old palette collapsed
    // to two: places (`amberDeep` #5D3000) and themes (`amberAccent` #A8541B)
    // were both amber-brown separated only by lightness, and people reused the
    // grey `inkMuted`. Introducing a distinct indigo hue for people restores a
    // true three-way split (indigo / amber / burnt-orange) while keeping the
    // amber pair for places+themes. All three carry a dark variant so nodes
    // stay legible against `bgWarm`'s deep charcoal in dark mode.

    /// People-category node hue — indigo, deliberately off the warm-amber axis
    /// so people read as a separate class from places/themes. Lifts toward a
    /// brighter periwinkle in dark mode to survive the charcoal background.
    static let graphPeople = Color(light: Color(hex: "3A4E9E"), dark: Color(hex: "8C9EE8"))
    /// Places-category node hue — deep archival amber (matches `amberDeep`,
    /// adaptive for dark). Kept in the warm family: places are the "where".
    static let graphPlaces = Color(light: Color(hex: "5D3000"), dark: Color(hex: "D9975A"))
    /// Themes-category node hue — burnt orange (matches `amberAccent`,
    /// adaptive for dark). Warmest of the three: themes are the "what".
    static let graphThemes = Color(light: Color(hex: "A8541B"), dark: Color(hex: "E8974D"))

    // V4 amber-density heatmap (4-step)
    static let densityNone   = Color(hex: "A8541B").opacity(0.06)
    static let densityLow    = Color(hex: "A8541B").opacity(0.20)
    static let densityMid    = Color(hex: "A8541B").opacity(0.45)
    static let densityHigh   = Color(hex: "A8541B").opacity(0.85)

    /// Foreground ink on amber-deep / amber-accent surfaces. Stays near-white
    /// in both light and dark schemes since the amber substrate carries the
    /// same chroma either way. Use instead of `Color.white` whenever drawing
    /// glyphs / dots on a saturated amber chip or artifact panel.
    static let onAmber        = Color(light: Color(hex: "FFFBF3"), dark: Color(hex: "FFF6E4"))

    // V4 status semantic tokens — adaptive in dark mode to preserve contrast
    // against `bgWarm` deep-charcoal-brown. Use these instead of system
    // `.green` / `.red` / `.orange`, which key off iOS system tints and lose
    // the warm-amber language under dark scheme.
    /// Granted / connected / OK state — warmer than system green so it sits
    /// against the amber palette without clashing.
    static let statusSuccess  = Color(light: Color(hex: "4C7A3F"), dark: Color(hex: "8FBE7A"))
    /// Denied / failed state — desaturated red that survives dark mode.
    static let statusError    = Color(light: Color(hex: "A23A2E"), dark: Color(hex: "E08577"))
    /// Limited / undetermined / requires-attention state — warm orange tied
    /// to the amber accent family.
    static let statusWarning  = Color(light: Color(hex: "A66A00"), dark: Color(hex: "E8A33B"))

    /// Transcribe-armed cue — cool blue tone used by the recording overlay to
    /// distinguish the "release-to-transcribe" gesture from the warmer
    /// "release-to-cancel" red. Tuned for legibility on the dark recording
    /// scrim in both schemes.
    static let transcribeBlue = Color(light: Color(hex: "4D8CFF"), dark: Color(hex: "7AA8FF"))

    // MARK: - Recording semantic tokens
    //
    // The press-to-talk overlay and bottom recording sheet share a single
    // dark warm substrate (#2D1E0C — same family as the v4 amber palette).
    // These tokens centralize the "white text / amber warn / dark substrate"
    // trio so callers do not hardcode `Color.white` or per-component RGB
    // tuples. They live in DSColor (semantic layer) on purpose — DSTokens
    // is generated from `design-tokens/tokens.json` and adding semantic
    // synonyms there would either drift or require a JSON edit.

    /// Recording substrate — the deep warm-brown scrim used by the recording
    /// overlay and sheet. Dark in both schemes since the recording UI is a
    /// "studio" mode that ignores ambient light.
    static let recordingSurface = Color(light: Color(hex: "2D1E0C"), dark: Color(hex: "1A1207"))

    /// Foreground ink on `recordingSurface` — near-white in both schemes
    /// because the substrate carries the dark amber chroma either way.
    /// Use instead of `Color.white` inside the recording overlay/sheet.
    static let onRecording = Color(light: .white, dark: .white)

    /// Soft-cap warn amber — bright warm amber that's legible on the dark
    /// recording surface (#FFB266). The recording sheet's timer warms to
    /// this past the 5:00 soft cap before flipping to `recordingRed` past
    /// 9:00. Lives here (and not in DSTokens) so design-tokens drift checks
    /// stay green.
    static let warnAmber = Color(red: 1.0, green: 0.70, blue: 0.35)

    // MARK: - V3 Warm-White Tokens

    /// 页面 / 屏幕背景 — 暖色调米白 / 深暖棕。
    /// v3 别名，现指向单一真源 `bgWarm`（→ `DSTokens.Colors.bgWarm`）。
    /// 曾经手写 `dark #1A1612`，与 v4/生成源不一致造成拼接接缝，已收敛。
    static let backgroundWarm = bgWarm
    /// 纯白表面（卡片、弹出面板）。指向生成真源，深色统一为 `#1F1C18`
    ///（此前手写 `#242018`，与 tokens.json 生成值漂移）。
    static let surfaceWhite = DSTokens.Colors.surfaceWhite
    /// 下凹表面 — 微暖灰色 / 深凹表面。指向生成真源，深色统一为 `#252118`
    ///（此前手写 `#131210`，比生成值更沉，造成同类下凹面深浅不一）。
    static let surfaceSunken = DSTokens.Colors.surfaceSunken

    /// 暖色背景主文本
    static let onBackgroundPrimary = Color(light: Color(hex: "2B2822"), dark: Color(hex: "EDE6DC"))
    /// 次要 / 弱化文本
    static let onBackgroundMuted = Color(light: Color(hex: "6B6560"), dark: Color(hex: "A09890"))
    /// 第三级细微文本
    static let onBackgroundSubtle = Color(light: Color(hex: "A39F99"), dark: Color(hex: "6A6460"))

    /// 强调色 — 深琥珀棕（替代 #000000 主色）。语义别名，值同 `amberDeep`（#5D3000）。
    static let accentAmber = amberDeep
    /// Adaptive accent for glyphs, strokes and text that sit directly on the
    /// ambient background: deep amber in light, lifted amber in dark. Use
    /// this instead of `accentAmber`/`DSTokens.Colors.accent` whenever the
    /// amber is INK (text, icon, outline) rather than a filled surface —
    /// #5D3000 vanishes against the dark-scheme charcoal background.
    static let accentOnBg = Color(light: Color(hex: "5D3000"), dark: Color(hex: "D9975A"))
    static let accentAmberHover = Color(hex: "7A3F00")
    static let accentSoft = Color(hex: "F5EDE3")
    static let accentBorder = Color(hex: "E8DCCA")

    /// 语义色：成功
    static let successGreen = Color(hex: "4C7A3F")
    static let successSoft = Color(hex: "EBF3E5")

    /// 语义色：警告
    static let warningAmber = Color(hex: "A66A00")
    static let warningSoft = Color(hex: "F8ECD6")

    /// 语义色：错误
    static let errorRed = Color(hex: "A23A2E")
    static let errorSoft = Color(hex: "F5E1DC")

    /// 热力图密度刻度（归档日历 / 侧边栏 16 周热力图）。
    /// Adaptive: in dark scheme the scale inverts perceptually — empty cells
    /// sink into the background and high density glows amber, instead of the
    /// light-scheme palette burning as a wall of white squares.
    static let heatmapEmpty = Color(light: Color(hex: "F0EBE3"), dark: Color(hex: "2E271E"))
    static let heatmapLow = Color(light: Color(hex: "E6D9C3"), dark: Color(hex: "4F3D26"))
    static let heatmapMid = Color(light: Color(hex: "C9A677"), dark: Color(hex: "96693A"))
    static let heatmapHigh = Color(light: Color(hex: "5D3000"), dark: Color(hex: "E09A55"))

    /// 边框令牌
    static let borderSubtle = Color(hex: "EDE8DF")
    static let borderDefault = Color(hex: "D6CEC0")

    // MARK: - Brand (unchanged)

    /// Brand archival amber. 语义别名，值同 `amberDeep`（#5D3000）。
    static let amberArchival = amberDeep

    // MARK: - Legacy tokens (v1 Material black-and-white era)
    //
    // These were imported from a generic Material Design palette before
    // the v4 Liquid Glass + warm-amber language was established. The pure
    // black `primary` and gray `surface*` were visually hostile to the
    // warm-cream glass surfaces, so all callers have been re-pointed at
    // v4 tokens via the mapping below. NEW code MUST NOT use these — go
    // straight to the v4 tokens (amberAccent / glassStd / inkPrimary ...).
    //
    // Migration map (use when editing a file that still calls these):
    //
    //   primary               → amberDeep            (or amberAccent for interactive)
    //   onPrimary             → Color.white
    //   surface / background  → bgWarm
    //   surfaceContainer*     → glassLo / glassStd / glassHi (by density)
    //   onSurface             → inkPrimary
    //   onSurfaceVariant      → inkMuted
    //   outline               → glassRim
    //   outlineVariant        → inkFaint
    //   error / onError       → errorRed / Color.white
    //   errorContainer        → errorSoft
    //   warning               → warningAmber
    //   warningContainer      → warningSoft
    //
    // Phase B will physically delete each of these once its call sites
    // have been migrated. For now they are kept as aliases so existing
    // call sites keep compiling against the corrected visual values.

    static let primary = amberDeep
    static let onPrimary = Color.white
    static let primaryContainer = amberAccent

    static let secondary = inkMuted

    static let tertiary = amberAccent

    static let surface = bgWarm
    static let surfaceContainerLowest = surfaceWhite
    static let surfaceContainerLow = glassLo
    static let surfaceContainer = glassStd
    static let surfaceContainerHigh = glassHi

    static let onSurface = inkPrimary
    static let onSurfaceVariant = inkMuted

    static let background = bgWarm

    static let outline = glassRim
    static let outlineVariant = inkFaint

    static let error = errorRed
    static let onError = Color.white
    static let errorContainer = errorSoft
}

// MARK: - Surface Elevated Shadow ViewModifier

struct SurfaceElevatedShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
    }
}

extension View {
    func surfaceElevatedShadow() -> some View {
        modifier(SurfaceElevatedShadow())
    }
}

// MARK: - Glass Surface ViewModifier

/// Applies the standard frosted-glass treatment (glassStd + ultraThinMaterial + rim).
/// When Reduce Transparency is enabled the blur is dropped and replaced with an opaque
/// warm fill so glyphs remain legible against any background.
struct GlassSurfaceModifier<S: Shape & InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        // Routes the standard frosted-glass treatment through the dual-track
        // engine (#771): iOS 26 → native Liquid Glass, iOS 16–25 → warm
        // faux-glass, Reduce Transparency → opaque warm fill. The engine owns
        // the rim + accessibility fallback, so this wrapper is now a thin
        // semantic alias (`.panel`) over `dpGlass`.
        content.dpGlass(.panel, in: shape)
    }
}

extension View {
    func glassSurface<S: Shape & InsettableShape>(in shape: S) -> some View {
        modifier(GlassSurfaceModifier(shape: shape))
    }
}
