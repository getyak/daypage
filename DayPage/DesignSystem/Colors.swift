import SwiftUI
import UIKit

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
    static let bgWarm        = Color(light: Color(hex: "FAF8F6"), dark: Color(hex: "1A1410"))
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

    // V4 amber-density heatmap (4-step)
    static let densityNone   = Color(hex: "A8541B").opacity(0.06)
    static let densityLow    = Color(hex: "A8541B").opacity(0.20)
    static let densityMid    = Color(hex: "A8541B").opacity(0.45)
    static let densityHigh   = Color(hex: "A8541B").opacity(0.85)

    // MARK: - V3 Warm-White Tokens

    /// 页面 / 屏幕背景 — 暖色调米白 / 深暖棕
    static let backgroundWarm = Color(light: Color(hex: "FAF8F6"), dark: Color(hex: "1A1612"))
    /// 纯白表面（卡片、弹出面板）
    static let surfaceWhite = Color(light: Color(hex: "FFFFFF"), dark: Color(hex: "242018"))
    /// 下凹表面 — 微暖灰色 / 深凹表面
    static let surfaceSunken = Color(light: Color(hex: "F3F0EB"), dark: Color(hex: "131210"))

    /// 暖色背景主文本
    static let onBackgroundPrimary = Color(light: Color(hex: "2B2822"), dark: Color(hex: "EDE6DC"))
    /// 次要 / 弱化文本
    static let onBackgroundMuted = Color(light: Color(hex: "6B6560"), dark: Color(hex: "A09890"))
    /// 第三级细微文本
    static let onBackgroundSubtle = Color(light: Color(hex: "A39F99"), dark: Color(hex: "6A6460"))

    /// 强调色 — 深琥珀棕（替代 #000000 主色）
    static let accentAmber = Color(hex: "5D3000")
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

    /// 热力图密度刻度（归档日历）
    static let heatmapEmpty = Color(hex: "F0EBE3")
    static let heatmapLow = Color(hex: "E6D9C3")
    static let heatmapMid = Color(hex: "C9A677")
    static let heatmapHigh = Color(hex: "5D3000")

    /// 边框令牌
    static let borderSubtle = Color(hex: "EDE8DF")
    static let borderDefault = Color(hex: "D6CEC0")

    // MARK: - Brand (unchanged)

    static let amberArchival = Color(hex: "5D3000")

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
    static let onPrimaryContainer = Color.white
    static let primaryFixed = amberDeep
    static let primaryFixedDim = amberAccent
    static let onPrimaryFixed = Color.white
    static let onPrimaryFixedVariant = Color.white.opacity(0.85)

    static let secondary = inkMuted
    static let onSecondary = Color.white
    static let secondaryContainer = glassLo
    static let onSecondaryContainer = inkPrimary
    static let secondaryFixed = glassStd
    static let secondaryFixedDim = glassLo
    static let onSecondaryFixed = inkPrimary
    static let onSecondaryFixedVariant = inkMuted

    static let tertiary = amberAccent
    static let onTertiary = Color.white
    static let tertiaryContainer = amberSoft
    static let onTertiaryContainer = amberDeep
    static let tertiaryFixed = amberSoft
    static let tertiaryFixedDim = amberRim
    static let onTertiaryFixed = amberDeep
    static let onTertiaryFixedVariant = amberDeep

    static let surface = bgWarm
    static let surfaceDim = glassLo
    static let surfaceBright = bgWarm
    static let surfaceContainerLowest = surfaceWhite
    static let surfaceContainerLow = glassLo
    static let surfaceContainer = glassStd
    static let surfaceContainerHigh = glassHi
    static let surfaceContainerHighest = glassHi

    static let onSurface = inkPrimary
    static let onSurfaceVariant = inkMuted
    static let inverseSurface = inkPrimary
    static let inverseOnSurface = bgWarm

    static let background = bgWarm
    static let onBackground = inkPrimary

    static let outline = glassRim
    static let outlineVariant = inkFaint

    static let error = errorRed
    static let onError = Color.white
    static let errorContainer = errorSoft
    static let onErrorContainer = errorRed

    static let warning = warningAmber
    static let warningContainer = warningSoft
    static let onWarningContainer = warningAmber

    static let surfaceTint = amberAccent
    static let inversePrimary = amberSoft
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
