import SwiftUI

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
}

// MARK: - Design System Colors

enum DSColor {
    // MARK: Brand
    static let amberArchival = Color(hex: "5D3000")

    // MARK: Primary Scale
    static let primary = Color(hex: "000000")
    static let onPrimary = Color(hex: "e2e2e2")
    static let primaryContainer = Color(hex: "3b3b3b")
    static let onPrimaryContainer = Color(hex: "ffffff")
    static let primaryFixed = Color(hex: "5e5e5e")
    static let primaryFixedDim = Color(hex: "474747")
    static let onPrimaryFixed = Color(hex: "ffffff")
    static let onPrimaryFixedVariant = Color(hex: "e2e2e2")

    // MARK: Secondary Scale
    static let secondary = Color(hex: "5f5e5e")
    static let onSecondary = Color(hex: "ffffff")
    static let secondaryContainer = Color(hex: "d6d4d3")
    static let onSecondaryContainer = Color(hex: "1b1c1c")
    static let secondaryFixed = Color(hex: "c8c6c6")
    static let secondaryFixedDim = Color(hex: "acabab")
    static let onSecondaryFixed = Color(hex: "1b1c1c")
    static let onSecondaryFixedVariant = Color(hex: "3b3b3b")

    // MARK: Tertiary Scale
    static let tertiary = Color(hex: "3b3b3c")
    static let onTertiary = Color(hex: "e3e2e2")
    static let tertiaryContainer = Color(hex: "747474")
    static let onTertiaryContainer = Color(hex: "ffffff")
    static let tertiaryFixed = Color(hex: "5e5e5e")
    static let tertiaryFixedDim = Color(hex: "464747")
    static let onTertiaryFixed = Color(hex: "ffffff")
    static let onTertiaryFixedVariant = Color(hex: "e3e2e2")

    // MARK: Surface Scale
    static let surface = Color(hex: "f9f9f9")
    static let surfaceDim = Color(hex: "dadada")
    static let surfaceBright = Color(hex: "f9f9f9")
    static let surfaceContainerLowest = Color(hex: "ffffff")
    static let surfaceContainerLow = Color(hex: "f3f3f3")
    static let surfaceContainer = Color(hex: "eeeeee")
    static let surfaceContainerHigh = Color(hex: "e8e8e8")
    static let surfaceContainerHighest = Color(hex: "e2e2e2")

    // MARK: On Surface
    static let onSurface = Color(hex: "1b1b1b")
    static let onSurfaceVariant = Color(hex: "474747")
    static let inverseSurface = Color(hex: "303030")
    static let inverseOnSurface = Color(hex: "f1f1f1")

    // MARK: Background
    static let background = Color(hex: "f9f9f9")
    static let onBackground = Color(hex: "1b1b1b")

    // MARK: Outline
    static let outline = Color(hex: "777777")
    static let outlineVariant = Color(hex: "c6c6c6")

    // MARK: Error
    static let error = Color(hex: "ba1a1a")
    static let onError = Color(hex: "ffffff")
    static let errorContainer = Color(hex: "ffdad6")
    static let onErrorContainer = Color(hex: "410002")

    // MARK: Other
    static let surfaceTint = Color(hex: "5e5e5e")
    static let inversePrimary = Color(hex: "c6c6c6")
}
